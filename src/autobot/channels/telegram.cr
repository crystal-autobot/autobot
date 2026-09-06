require "base64"
require "http/client"
require "json"
require "uri"
require "./base"
require "./telegram_media"
require "../constants"
require "../cron/formatter"
require "../cron/service"
require "../http"

module Autobot::Channels
  # Converts Markdown to Telegram-safe HTML.
  #
  # Telegram supports: <b>, <i>, <u>, <s>, <code>, <pre>, <a>, <blockquote>
  # All <, >, & outside tags must be escaped. Code/pre cannot contain other tags.
  module MarkdownToTelegramHTML
    TELEGRAM_MAX_LENGTH = 4096

    # Prefix (no closing ">") so it matches both <pre><code> and
    # <pre><code class="language-...">; the full open tag is recovered later.
    HTML_CODE_OPEN  = "<pre><code"
    HTML_CODE_CLOSE = "</code></pre>"

    CODE_BLOCK_PREFIX  = "\x00CB"
    INLINE_CODE_PREFIX = "\x00IC"
    UNDERSCORE_PREFIX  = "\x00US"
    SUFFIX             = "\x00"

    HEADER_REGEX     = Regex.new(%q(^#{1,6}\s+(.+)$), Regex::Options::MULTILINE)
    BLOCKQUOTE_REGEX = /^>\s*(.*)$/m
    HR_REGEX         = /^[-*_]{3,}\s*$/m

    CODE_BLOCK_REGEX     = /```(\w*)\n?([\s\S]*?)```/
    INLINE_CODE_REGEX    = /`([^`]+)`/
    UNDERSCORE_RUN_REGEX = /_{3,}/

    LINK_REGEX            = /\[([^\]]+)\]\(([^)]+)\)/
    BOLD_STAR_REGEX       = /\*\*(.+?)\*\*/
    BOLD_UNDERSCORE_REGEX = /__(.+?)__/
    ITALIC_REGEX          = /(?<![a-zA-Z0-9])_([^_]+)_(?![a-zA-Z0-9])/
    STRIKETHROUGH_REGEX   = /~~(.+?)~~/
    BULLET_LIST_REGEX     = /^[-*]\s+/m

    HTML_TAG_REGEX   = /<(\/?)(b|i|code|pre|a|s|u)(?:\s[^>]*)?>/
    STRIP_HTML_REGEX = /<\/?(?:b|i|code|pre|a|s|u)(?:\s[^>]*)?>/

    def self.convert(text : String) : String
      return "" if text.empty?

      code_blocks = [] of String
      inline_codes = [] of String
      underscore_runs = [] of String

      result = text
      result = extract_code_blocks(result, code_blocks)
      result = extract_inline_code(result, inline_codes)

      # Strip block elements (before HTML escape since > would be escaped)
      result = result.gsub(HEADER_REGEX, "\\1")
      result = result.gsub(BLOCKQUOTE_REGEX, "\\1")
      result = result.gsub(HR_REGEX, "")

      result = escape_html(result)
      result = protect_underscore_runs(result, underscore_runs)
      result = convert_inline_formatting(result)
      result = restore_underscore_runs(result, underscore_runs)
      result = restore_placeholders(result, inline_codes, code_blocks)

      result.strip
    end

    def self.escape_html(text : String) : String
      text.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;")
    end

    def self.valid_html?(text : String) : Bool
      stack = [] of String
      text.scan(HTML_TAG_REGEX).each do |match|
        if match[1] == "/"
          return false if stack.empty? || stack.last != match[2]
          stack.pop
        else
          stack << match[2]
        end
      end
      stack.empty?
    end

    def self.strip_html(text : String) : String
      text.gsub(STRIP_HTML_REGEX, "")
    end

    def self.split_message(text : String) : Array(String)
      return [text] if text.size <= TELEGRAM_MAX_LENGTH

      chunks = [] of String
      code_block_segments(text).each do |segment|
        next if segment.empty?
        if segment.starts_with?(HTML_CODE_OPEN)
          split_code_block(segment, chunks)
        else
          split_by_paragraphs(segment).each { |chunk| chunks << chunk }
        end
      end
      chunks
    end

    # Splits text into alternating plain and complete <pre><code>...</code></pre>
    # segments so neither can be broken across a chunk boundary.
    private def self.code_block_segments(text : String) : Array(String)
      segments = [] of String
      cursor = 0

      while open_index = text.index(HTML_CODE_OPEN, cursor)
        close_index = text.index(HTML_CODE_CLOSE, open_index)
        break unless close_index

        block_end = close_index + HTML_CODE_CLOSE.size
        segments << text[cursor, open_index - cursor] if open_index > cursor
        segments << text[open_index, block_end - open_index]
        cursor = block_end
      end

      segments << text[cursor..] if cursor < text.size
      segments
    end

    # Splits an oversized code block into self-contained <pre><code> chunks that
    # each stay within the length limit.
    private def self.split_code_block(block : String, chunks : Array(String)) : Nil
      if block.size <= TELEGRAM_MAX_LENGTH
        chunks << block
        return
      end

      open_tag = code_block_open_tag(block)
      inner = block[open_tag.size, block.size - open_tag.size - HTML_CODE_CLOSE.size]
      budget = TELEGRAM_MAX_LENGTH - open_tag.size - HTML_CODE_CLOSE.size

      pack_code_lines(inner, budget).each do |piece|
        chunks << "#{open_tag}#{piece}#{HTML_CODE_CLOSE}"
      end
    end

    private def self.code_block_open_tag(block : String) : String
      pre_end = block.index('>')
      code_end = pre_end ? block.index('>', pre_end + 1) : nil
      code_end ? block[0, code_end + 1] : "<pre><code>"
    end

    private def self.pack_code_lines(content : String, budget : Int32) : Array(String)
      pieces = [] of String
      buffer = String::Builder.new
      buffer_size = 0

      each_code_unit(content, budget) do |unit|
        if buffer_size > 0 && buffer_size + unit.size > budget
          pieces << buffer.to_s
          buffer = String::Builder.new
          buffer_size = 0
        end
        buffer << unit
        buffer_size += unit.size
      end

      pieces << buffer.to_s if buffer_size > 0
      pieces
    end

    # Yields the content line by line (newlines preserved), hard-splitting any
    # single line that exceeds the budget so concatenation reproduces the input.
    private def self.each_code_unit(content : String, budget : Int32, & : String ->) : Nil
      lines = content.split('\n')
      last_index = lines.size - 1

      lines.each_with_index do |line, index|
        unit = index == last_index ? line : "#{line}\n"
        next if unit.empty?

        if unit.size <= budget
          yield unit
        else
          0.step(to: unit.size - 1, by: budget) { |start| yield unit[start, budget] }
        end
      end
    end

    private def self.extract_code_blocks(text : String, store : Array(String)) : String
      text.gsub(CODE_BLOCK_REGEX) do |_, match|
        store << build_code_block_html(match[1], escape_html(match[2]))
        "#{CODE_BLOCK_PREFIX}#{store.size - 1}#{SUFFIX}"
      end
    end

    private def self.build_code_block_html(lang : String, escaped_code : String) : String
      if lang.empty?
        "<pre><code>#{escaped_code}</code></pre>"
      else
        "<pre><code class=\"language-#{escape_html(lang)}\">#{escaped_code}</code></pre>"
      end
    end

    private def self.extract_inline_code(text : String, store : Array(String)) : String
      text.gsub(INLINE_CODE_REGEX) do |_, match|
        store << "<code>#{escape_html(match[1])}</code>"
        "#{INLINE_CODE_PREFIX}#{store.size - 1}#{SUFFIX}"
      end
    end

    private def self.protect_underscore_runs(text : String, store : Array(String)) : String
      text.gsub(UNDERSCORE_RUN_REGEX) do |run|
        store << run
        "#{UNDERSCORE_PREFIX}#{store.size - 1}#{SUFFIX}"
      end
    end

    private def self.restore_underscore_runs(text : String, store : Array(String)) : String
      result = text
      store.each_with_index do |run, i|
        result = result.gsub("#{UNDERSCORE_PREFIX}#{i}#{SUFFIX}", run)
      end
      result
    end

    private def self.convert_inline_formatting(text : String) : String
      result = text
      result = result.gsub(LINK_REGEX, %(<a href="\\2">\\1</a>))
      result = result.gsub(BOLD_STAR_REGEX, "<b>\\1</b>")
      result = result.gsub(BOLD_UNDERSCORE_REGEX, "<b>\\1</b>")
      result = result.gsub(ITALIC_REGEX, "<i>\\1</i>")
      result = result.gsub(STRIKETHROUGH_REGEX, "<s>\\1</s>")
      result = result.gsub(BULLET_LIST_REGEX, "\u{2022} ")
      result
    end

    private def self.restore_placeholders(text : String, inline_codes : Array(String), code_blocks : Array(String)) : String
      result = text
      inline_codes.each_with_index do |html, i|
        result = result.gsub("#{INLINE_CODE_PREFIX}#{i}#{SUFFIX}", html)
      end
      code_blocks.each_with_index do |html, i|
        result = result.gsub("#{CODE_BLOCK_PREFIX}#{i}#{SUFFIX}", html)
      end
      result
    end

    private def self.split_by_paragraphs(text : String) : Array(String)
      chunks = [] of String
      current = ""

      text.split("\n\n").each do |para|
        candidate = current.empty? ? para : "#{current}\n\n#{para}"
        if candidate.size <= TELEGRAM_MAX_LENGTH
          current = candidate
        else
          chunks << current unless current.empty?
          current = accumulate_lines(para, chunks)
        end
      end

      chunks << current unless current.empty?
      chunks
    end

    private def self.accumulate_lines(para : String, chunks : Array(String)) : String
      return para if para.size <= TELEGRAM_MAX_LENGTH

      current = ""
      para.split("\n").each do |line|
        candidate = current.empty? ? line : "#{current}\n#{line}"
        if candidate.size <= TELEGRAM_MAX_LENGTH
          current = candidate
        else
          chunks << current unless current.empty?
          current = line[0, TELEGRAM_MAX_LENGTH]
        end
      end
      current
    end
  end

  # Telegram channel using long polling via the Bot API.
  #
  # Features:
  # - Long polling (no webhook/public IP needed)
  # - Built-in commands (/start, /reset, /help)
  # - Custom commands (macros + bash scripts)
  # - Media handling (photos, voice, documents)
  # - Typing indicators
  # - Markdown-to-Telegram HTML conversion
  # - Allow list for access control
  class TelegramChannel < Channel
    Log = ::Log.for("channels.telegram")

    TELEGRAM_API_BASE = "https://api.telegram.org"
    TOPIC_SEPARATOR   = ':'
    GENERAL_TOPIC     = 1_i64

    alias Sender = NamedTuple(chat_id: String, user_id: String, username: String?, first_name: String, sender_id: String, is_group: Bool, topic: Int64?)
    POLL_TIMEOUT    =  30
    TYPING_INTERVAL = 4.0
    MAX_IMAGE_SIZE  = 20 * 1024 * 1024 # 20 MB

    MEDIA_LOG_LABEL     = "[media]"
    EMPTY_MESSAGE_LABEL = "[empty message]"
    SERVICE_FIELDS      = %w[new_chat_members left_chat_member new_chat_title new_chat_photo delete_chat_photo
      group_chat_created supergroup_chat_created channel_chat_created message_auto_delete_timer_changed
      migrate_to_chat_id migrate_from_chat_id pinned_message forum_topic_created forum_topic_edited
      forum_topic_closed forum_topic_reopened general_forum_topic_hidden general_forum_topic_unhidden
      video_chat_scheduled video_chat_started video_chat_ended video_chat_participants_invited
      proximity_alert_triggered write_access_allowed boost_added chat_background_set]

    @offset : Int64 = 0_i64
    @bot_username : String = ""
    @bot_mention_regex : Regex? = nil
    @typing_channels : Set(String) = Set(String).new
    @chat_log_mutex : Mutex = Mutex.new
    @media_extractor : TelegramMedia

    def initialize(
      @bus : Bus::MessageBus,
      @token : String,
      @allow_from : Array(String) = [] of String,
      @proxy : String? = nil,
      @topics : Array(Int64) = [] of Int64,
      @custom_commands : Config::CustomCommandsConfig = Config::CustomCommandsConfig.new,
      @session_manager : Session::Manager? = nil,
      @transcriber : Transcriber? = nil,
      @cron_service : Cron::Service? = nil,
      @inbox : Media::Inbox? = nil,
    )
      super(Constants::CHANNEL_TELEGRAM, @bus, @allow_from)
      @media_extractor = TelegramMedia.new(->(file_id : String) { download_telegram_file_bytes(file_id) }, @transcriber, @inbox)
    end

    GETME_MAX_ATTEMPTS = 5
    GETME_RETRY_DELAY  = 2.seconds

    def start : Nil
      if @token.empty?
        Log.error { "Telegram bot token not configured" }
        return
      end

      @running = true

      resolve_bot_username

      register_commands

      Log.info { "Starting Telegram bot (long polling)..." }
      poll_updates
    end

    # Resolves the bot username via getMe, retrying on transient failures.
    # Mention detection in groups depends on it, so a single startup hiccup
    # must not silently disable group replies for the process lifetime.
    private def resolve_bot_username : Nil
      GETME_MAX_ATTEMPTS.times do |attempt|
        if username = fetch_bot_username
          @bot_username = username
          Log.info { "Telegram bot @#{@bot_username} connected" }
          return
        end

        Log.warn { "getMe failed (attempt #{attempt + 1}/#{GETME_MAX_ATTEMPTS})" }
        sleep GETME_RETRY_DELAY unless attempt == GETME_MAX_ATTEMPTS - 1
      end

      Log.error { "Could not resolve bot username after #{GETME_MAX_ATTEMPTS} attempts; group mention detection is disabled until restart" }
    end

    private def fetch_bot_username : String?
      return nil unless bot_info = api_request("getMe")
      bot_info["username"]?.try(&.as_s)
    end

    def stop : Nil
      @running = false
      @typing_channels.clear
    end

    MULTIPART_BOUNDARY     = "----AutobotMediaBoundary"
    PHOTO_CAPTION_LIMIT    = 1024
    DOCUMENT_CAPTION_LIMIT = 1024

    def send_message(message : Bus::OutboundMessage) : Nil
      stop_typing(message.chat_id)

      if attachment = find_sendable_attachment(message.media?)
        send_media(message.chat_id, attachment, message.content)
        return
      end

      return if message.content.strip.empty?

      html = MarkdownToTelegramHTML.convert(message.content)
      html = MarkdownToTelegramHTML.strip_html(html) unless MarkdownToTelegramHTML.valid_html?(html)

      MarkdownToTelegramHTML.split_message(html).each do |chunk|
        send_html_chunk(message.chat_id, chunk)
      end
    end

    private def send_html_chunk(chat_id : String, html : String) : Nil
      result = api_request("sendMessage", {
        "chat_id"    => chat_id,
        "text"       => html,
        "parse_mode" => "HTML",
      })

      unless result
        Log.warn { "HTML parse failed, falling back to plain text" }
        api_request("sendMessage", {
          "chat_id" => chat_id,
          "text"    => MarkdownToTelegramHTML.strip_html(html),
        })
      end
    end

    private def find_sendable_attachment(media : Array(Bus::MediaAttachment)?) : Bus::MediaAttachment?
      return nil unless media
      media.find(&.data)
    end

    private def find_photo_attachment(media : Array(Bus::MediaAttachment)?) : Bus::MediaAttachment?
      return nil unless media
      media.find { |attachment| attachment.type == "photo" && attachment.data }
    end

    private def get_media_params(attachment : Bus::MediaAttachment)
      case attachment.type
      when "photo"
        {api_method: "sendPhoto", field_name: "photo", filename: media_filename(attachment, "image.png"), content_type: attachment.mime_type || "image/png"}
      when "animation"
        {api_method: "sendAnimation", field_name: "animation", filename: media_filename(attachment, "animation.gif"), content_type: attachment.mime_type || "image/gif"}
      when "voice"
        {api_method: "sendVoice", field_name: "voice", filename: media_filename(attachment, "voice.ogg"), content_type: attachment.mime_type || "audio/ogg"}
      when "audio"
        {api_method: "sendAudio", field_name: "audio", filename: media_filename(attachment, "audio.mp3"), content_type: attachment.mime_type || "audio/mpeg"}
      else
        {api_method: "sendDocument", field_name: "document", filename: media_filename(attachment, "file"), content_type: attachment.mime_type || "application/octet-stream"}
      end
    end

    private def send_media(chat_id : String, attachment : Bus::MediaAttachment, caption : String) : Nil
      data = attachment.data
      unless data
        Log.warn { "Media attachment has no data, falling back to text" }
        send_html_chunk(chat_id, MarkdownToTelegramHTML.escape_html(caption))
        return
      end

      file_bytes = Base64.decode(data)
      params = get_media_params(attachment)

      send_media_request(chat_id, file_bytes, caption,
        api_method: params[:api_method],
        field_name: params[:field_name],
        filename: params[:filename],
        content_type: params[:content_type])
    rescue ex
      Log.error { "Error sending media: #{ex.message}" }
      send_html_chunk(chat_id, MarkdownToTelegramHTML.escape_html(caption))
    end

    private def send_media_request(
      chat_id : String,
      file_bytes : Bytes,
      caption : String,
      api_method : String,
      field_name : String,
      filename : String,
      content_type : String,
    ) : Nil
      body = build_media_multipart(chat_id, file_bytes, caption,
        field_name: field_name, filename: filename, content_type: content_type)

      headers = HTTP::Headers{
        "Content-Type" => "multipart/form-data; boundary=#{MULTIPART_BOUNDARY}",
      }

      fallback_needed = false

      with_api_client do |client|
        response = client.post("/bot#{@token}/#{api_method}", headers: headers, body: body)

        unless response.status_code == 200
          Log.error { "#{api_method} failed (HTTP #{response.status_code}): #{parse_error_description(response.body)}" }
          fallback_needed = true
        end
      end

      if fallback_needed
        send_html_chunk(chat_id, MarkdownToTelegramHTML.escape_html(caption))
      end
    end

    private def build_media_multipart(
      chat_id : String,
      file_bytes : Bytes,
      caption : String,
      field_name : String,
      filename : String,
      content_type : String,
    ) : String
      io = IO::Memory.new

      chat_params(chat_id).each do |name, value|
        io << "--" << MULTIPART_BOUNDARY << "\r\n"
        io << "Content-Disposition: form-data; name=\"" << name << "\"\r\n\r\n"
        io << value << "\r\n"
      end

      # file field (binary)
      io << "--" << MULTIPART_BOUNDARY << "\r\n"
      io << "Content-Disposition: form-data; name=\"" << field_name << "\"; filename=\"" << filename << "\"\r\n"
      io << "Content-Type: " << content_type << "\r\n\r\n"
      io.write(file_bytes)
      io << "\r\n"

      # caption field
      truncated_caption = caption.size > DOCUMENT_CAPTION_LIMIT ? caption[0, DOCUMENT_CAPTION_LIMIT] : caption
      io << "--" << MULTIPART_BOUNDARY << "\r\n"
      io << "Content-Disposition: form-data; name=\"caption\"\r\n\r\n"
      io << truncated_caption << "\r\n"

      io << "--" << MULTIPART_BOUNDARY << "--\r\n"
      io.to_s
    end

    private def media_filename(attachment : Bus::MediaAttachment, default : String) : String
      if path = attachment.file_path
        File.basename(path)
      else
        default
      end
    end

    # Legacy method kept for backward compatibility with tests.
    private def build_photo_multipart(chat_id : String, photo_bytes : Bytes, caption : String) : String
      build_media_multipart(chat_id, photo_bytes, caption,
        field_name: "photo", filename: "image.png", content_type: "image/png")
    end

    private def poll_updates : Nil
      while @running
        begin
          params = {
            "offset"          => (@offset + 1).to_s,
            "timeout"         => POLL_TIMEOUT.to_s,
            "allowed_updates" => %(["message"]),
          }

          response = api_get("getUpdates", params)
          next unless response

          if updates = response.as_a?
            updates.each do |update|
              @offset = update["update_id"].as_i64
              if msg = update["message"]?
                spawn { process_message(msg) }
              end
            end
          end
        rescue ex
          Log.error { "Polling error: #{ex.message}" }
          sleep(2.seconds) if @running
        end
      end
    end

    private def process_message(msg : JSON::Any) : Nil
      sender = extract_sender(msg)
      return unless sender

      if service_message?(msg)
        Log.debug { "Ignored service message in #{sender[:chat_id]}" }
        return
      end

      return if handle_command_message(msg, sender)

      display_name = sender[:username] ? "@#{sender[:username]}" : sender[:first_name]

      # Record every group message (regardless of allowlist or mention) so the
      # rolling chat log stays complete.
      if sender[:is_group]
        record_chat_log(sender[:chat_id], display_name, typed_text(msg) || MEDIA_LOG_LABEL)
      end

      # Stay silent for group messages that do not address the bot, before the
      # allowlist check, so passive group chatter never triggers a denial reply.
      unless addressed?(msg, sender)
        Log.debug { "Logged group message from #{sender[:sender_id]} silently" }
        return
      end

      unless allowed?(sender[:sender_id])
        Log.warn { "Access denied for sender #{sender[:sender_id]} on telegram. Add to allow_from to grant access." }
        send_reply(sender[:chat_id], access_denied_message(sender[:sender_id]))
        return
      end

      content, media_attachments = build_content_and_media(msg)
      content = prepend_reply_context(content, extract_reply_context(msg))
      content_to_process = sender[:is_group] ? "#{display_name}: #{content}" : content

      Log.debug { "Message from #{sender[:sender_id]}: #{content_to_process}" }
      start_typing(sender[:chat_id])

      handle_message(
        sender_id: sender[:sender_id],
        chat_id: sender[:chat_id],
        content: content_to_process,
        media: media_attachments.empty? ? nil : media_attachments,
        metadata: build_metadata(msg, sender),
      )
    rescue ex
      Log.error { "Error processing message: #{ex.message}" }
    end

    private def extract_sender(msg : JSON::Any) : Sender?
      chat = msg["chat"]?
      from = msg["from"]?
      return nil unless chat && from

      topic = msg["message_thread_id"]?.try(&.as_i64?) if msg["is_topic_message"]?.try(&.as_bool?)
      topic ||= GENERAL_TOPIC if chat["is_forum"]?.try(&.as_bool?)
      chat_id = topic ? "#{chat["id"].as_i64}#{TOPIC_SEPARATOR}#{topic}" : chat["id"].as_i64.to_s
      user_id = from["id"].as_i64.to_s
      username = from["username"]?.try(&.as_s)
      first_name = from["first_name"]?.try(&.as_s) || "User"
      sender_id = username ? "#{user_id}|#{username}" : user_id
      is_group = chat["type"]?.try(&.as_s) != "private"

      {
        chat_id:    chat_id,
        user_id:    user_id,
        username:   username,
        first_name: first_name,
        sender_id:  sender_id,
        is_group:   is_group,
        topic:      topic,
      }
    end

    private def extract_reply_context(msg : JSON::Any) : String?
      reply_msg = msg["reply_to_message"]?
      return nil unless reply_msg

      reply_msg["text"]?.try(&.as_s) || reply_msg["caption"]?.try(&.as_s)
    end

    private def service_message?(msg : JSON::Any) : Bool
      SERVICE_FIELDS.any? { |field| !msg[field]?.nil? }
    end

    private def typed_text(msg : JSON::Any) : String?
      parts = [msg["text"]?.try(&.as_s?), msg["caption"]?.try(&.as_s?)].compact
      parts.empty? ? nil : parts.join("\n")
    end

    private def build_content_and_media(msg : JSON::Any) : {String, Array(Bus::MediaAttachment)}
      typed = typed_text(msg)
      media_parts, media_attachments = @media_extractor.extract(msg, !typed.nil?)

      content_parts = [typed].compact.concat(media_parts)
      content = content_parts.empty? ? EMPTY_MESSAGE_LABEL : content_parts.join("\n")
      {content, media_attachments}
    end

    private def download_telegram_file_bytes(file_id : String) : Bytes?
      result = api_request("getFile", {"file_id" => file_id})
      return nil unless result

      file_path = result["file_path"]?.try(&.as_s)
      return nil unless file_path

      file_size = result["file_size"]?.try(&.as_i64?) || 0_i64
      if file_size > MAX_IMAGE_SIZE
        Log.warn { "File too large (#{file_size} bytes), skipping download" }
        return nil
      end

      with_api_client do |client|
        client.get("/file/bot#{@token}/#{file_path}") do |response|
          if response.status_code == 200
            io = IO::Memory.new(file_size.to_i32)
            IO.copy(response.body_io, io)
            io.to_slice
          else
            Log.warn { "Failed to download file: HTTP #{response.status_code}" }
            nil
          end
        end
      end
    rescue ex
      Log.error { "Error downloading telegram file: #{ex.message}" }
      nil
    end

    private def build_metadata(msg : JSON::Any, sender : Sender) : Hash(String, String)
      {
        "message_id" => msg["message_id"].as_i64.to_s,
        "user_id"    => sender[:user_id],
        "username"   => sender[:username] || "",
        "first_name" => sender[:first_name],
        "is_group"   => sender[:is_group].to_s,
        "topic"      => sender[:topic].to_s,
      }
    end

    private def handle_command(text : String, chat_id : String, sender_id : String, first_name : String) : Nil
      unless allowed?(sender_id)
        Log.warn { "Unauthorized command attempt from #{sender_id}" }
        send_reply(chat_id, access_denied_message(sender_id))
        return
      end

      parts = text.split(' ', 2)
      command = parts[0].downcase.split('@').first.lstrip('/')
      args = parts[1]?.try(&.strip) || ""

      case command
      when "start"
        send_reply(chat_id, "Hi #{first_name}! I'm Autobot.\n\nSend me a message and I'll respond!\nType /help to see available commands.")
      when "reset"
        handle_reset(chat_id)
      when "cron"
        send_cron_list(chat_id)
      when "help"
        send_help(chat_id)
      else
        handle_custom_command(command, args, chat_id, sender_id)
      end
    end

    private def handle_reset(chat_id : String) : Nil
      session_manager = session_manager_for_reset(chat_id)
      return unless session_manager

      session_key, cleared_count = reset_chat_session(session_manager, chat_id)
      Log.info { "Session reset for #{session_key} (cleared #{cleared_count} messages)" }
      send_reply(chat_id, "Conversation history cleared. Let's start fresh!")
    end

    private def session_manager_for_reset(chat_id : String) : Session::Manager?
      session_manager = @session_manager
      unless session_manager
        send_reply(chat_id, "Session management is not available.")
        return nil
      end
      session_manager
    end

    private def reset_chat_session(session_manager : Session::Manager, chat_id : String) : {String, Int32}
      session_key = "telegram:#{chat_id}"
      session = session_manager.get_or_create(session_key)
      cleared_count = session.messages.size
      session.clear
      session_manager.save(session)
      {session_key, cleared_count}
    end

    private def send_cron_list(chat_id : String) : Nil
      cron = @cron_service
      unless cron
        send_reply(chat_id, "Cron service is not available.")
        return
      end

      jobs = cron.list_jobs(owner: Cron.owner_key(Constants::CHANNEL_TELEGRAM, chat_id))

      if jobs.empty?
        send_reply(chat_id, "No scheduled jobs.\n\nAsk me in chat to schedule something.")
        return
      end

      lines = ["<b>Scheduled jobs (#{jobs.size})</b>"]
      jobs.each_with_index do |job, idx|
        lines << format_cron_job_html(job, idx + 1)
      end

      text = lines.join("\n\n")
      MarkdownToTelegramHTML.split_message(text).each do |chunk|
        send_reply(chat_id, chunk)
      end
    end

    private def format_cron_job_html(job : Cron::CronJob, index : Int32) : String
      Cron::Formatter.format_job_line_html(job, index)
    end

    private def send_help(chat_id : String) : Nil
      lines = [
        "<b>Autobot commands</b>\n",
        "/start - Start the bot",
        "/reset - Reset conversation history",
        "/cron - Show scheduled jobs",
        "/help - Show this help message",
      ]

      @custom_commands.macros.each do |cmd, entry|
        lines << "/#{cmd} - #{command_description(entry, cmd)}"
      end
      @custom_commands.scripts.each do |cmd, entry|
        lines << "/#{cmd} - #{command_description(entry, cmd)}"
      end

      lines << "\nSend me a text message to chat!"

      api_request("sendMessage", {
        "chat_id"    => chat_id,
        "text"       => lines.join("\n"),
        "parse_mode" => "HTML",
      })
    end

    private def handle_custom_command(command : String, args : String, chat_id : String, sender_id : String) : Nil
      if entry = @custom_commands.macros[command]?
        prompt = entry.value
        content = args.empty? ? prompt : "#{prompt}\n\n#{args}"
        start_typing(chat_id)
        handle_message(
          sender_id: sender_id,
          chat_id: chat_id,
          content: content,
          metadata: {"custom_command" => command},
        )
        return
      end

      if entry = @custom_commands.scripts[command]?
        start_typing(chat_id)
        execute_script(entry.value, args, chat_id)
        return
      end

      send_reply(chat_id, "Unknown command /#{command}. Type /help to see the available commands.")
    end

    SCRIPT_OUTPUT_LIMIT = 4000
    READ_CHUNK_SIZE     = 4096

    private def execute_script(script_path : String, args : String, chat_id : String) : Nil
      expanded = Path[script_path].expand(home: true).to_s

      if error = validate_script_path(expanded)
        send_reply(chat_id, "Security error: #{error}")
        return
      end

      cmd_args = parse_script_args(args)

      process = Process.new(
        expanded,
        args: cmd_args,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe,
      )

      # stderr must be read concurrently with stdout: a child blocked on a full pipe never exits
      error_channel = ::Channel(String).new(1)
      spawn { error_channel.send(read_limited_io(process.error, SCRIPT_OUTPUT_LIMIT)) }

      output = read_limited_io(process.output, SCRIPT_OUTPUT_LIMIT)
      error_output = error_channel.receive
      status = process.wait

      result = if status.success?
                 output.empty? ? "Script completed successfully." : output
               else
                 "Script failed (exit #{status.exit_code}):\n#{error_output}".strip
               end

      stop_typing(chat_id)
      send_reply(chat_id, "<pre>#{MarkdownToTelegramHTML.escape_html(result)}</pre>")
    rescue ex
      stop_typing(chat_id)
      send_reply(chat_id, "Error running script")
    end

    private def validate_script_path(script_path : String) : String?
      unless File.exists?(script_path)
        return "Script not found"
      end

      unless File.file?(script_path)
        return "Path is not a regular file"
      end

      begin
        real_path = File.realpath(script_path)
      rescue
        return "Cannot resolve script path"
      end

      info = File.info(real_path)
      unless info.permissions.owner_execute? || info.permissions.group_execute? || info.permissions.other_execute?
        return "Script is not executable"
      end

      nil
    end

    private def parse_script_args(args_str : String) : Array(String)
      return [] of String if args_str.strip.empty?

      args = [] of String
      current_arg = String::Builder.new
      in_quotes = false
      quote_char = '\0'
      escaped = false

      args_str.each_char do |char|
        if escaped
          current_arg << char
          escaped = false
          next
        end

        case char
        when '\\'
          escaped = true
        when '"', '\''
          if in_quotes
            if char == quote_char
              in_quotes = false
              quote_char = '\0'
            else
              current_arg << char
            end
          else
            in_quotes = true
            quote_char = char
          end
        when ' ', '\t'
          if in_quotes
            current_arg << char
          else
            unless current_arg.empty?
              args << current_arg.to_s
              current_arg = String::Builder.new
            end
          end
        else
          current_arg << char
        end
      end

      unless current_arg.empty?
        args << current_arg.to_s
      end

      args
    end

    private def start_typing(chat_id : String) : Nil
      return if @typing_channels.includes?(chat_id)
      @typing_channels.add(chat_id)

      spawn(name: "typing-#{chat_id}") do
        while @running && @typing_channels.includes?(chat_id)
          api_request("sendChatAction", {"chat_id" => chat_id, "action" => "typing"})
          sleep(TYPING_INTERVAL.seconds)
        end
      end
    end

    private def stop_typing(chat_id : String) : Nil
      @typing_channels.delete(chat_id)
    end

    private def register_commands : Nil
      commands = [
        {"command" => "start", "description" => "Start the bot"},
        {"command" => "reset", "description" => "Reset conversation history"},
        {"command" => "cron", "description" => "Show scheduled jobs"},
        {"command" => "help", "description" => "Show available commands"},
      ]

      @custom_commands.macros.each do |cmd, entry|
        commands << {"command" => cmd, "description" => command_description(entry, cmd)}
      end
      @custom_commands.scripts.each do |cmd, entry|
        commands << {"command" => cmd, "description" => command_description(entry, cmd)}
      end

      api_request("setMyCommands", {"commands" => commands.to_json})
    rescue ex
      Log.warn { "Failed to register bot commands: #{ex.message}" }
    end

    private def command_description(entry : Config::CustomCommandEntry, command_name : String) : String
      entry.description || command_name.gsub(/[_-]/, " ").capitalize
    end

    private def access_denied_message(sender_id : String) : String
      if @allow_from.empty?
        "This bot has no authorized users yet.\n" \
        "Add your user ID to <code>allow_from</code> in config.yml to get started.\n\n" \
        "Your ID: <code>#{MarkdownToTelegramHTML.escape_html(sender_id)}</code>"
      else
        "Access denied. You are not in the authorized users list."
      end
    end

    protected def build_api_client : ::HTTP::Client
      Autobot::HTTP.build_client(TELEGRAM_API_BASE)
    end

    private def with_api_client(read_timeout : Time::Span? = Autobot::HTTP::DEFAULT_READ_TIMEOUT, &)
      client = build_api_client
      client.read_timeout = read_timeout if read_timeout
      Autobot::HTTP.with_client(client, proxy: @proxy) do |http_client|
        yield http_client
      end
    end

    private def api_request(method : String, params : Hash(String, String) = {} of String => String) : JSON::Any?
      params = params.merge(chat_params(params["chat_id"])) if params.has_key?("chat_id")
      with_api_client do |client|
        response = client.post("/bot#{@token}/#{method}", form: URI::Params.encode(params))

        if response.status_code == 200
          data = JSON.parse(response.body)
          if data["ok"]?.try(&.as_bool)
            return data["result"]?
          else
            Log.warn { "Telegram API #{method} failed: #{data["description"]?.try(&.as_s)}" }
          end
        else
          Log.error { "Telegram API #{method} HTTP #{response.status_code}: #{parse_error_description(response.body)}" }
        end

        nil
      end
    rescue ex
      Log.error { "Telegram API #{method} error: #{ex.message}" }
      nil
    end

    private def parse_error_description(body : String) : String
      JSON.parse(body)["description"]?.try(&.as_s) || "unknown error"
    rescue
      "unparseable response"
    end

    private def api_get(method : String, params : Hash(String, String) = {} of String => String) : JSON::Any?
      with_api_client(read_timeout: (POLL_TIMEOUT + 10).seconds) do |client|
        query = URI::Params.encode(params)
        response = client.get("/bot#{@token}/#{method}?#{query}")

        if response.status_code == 200
          data = JSON.parse(response.body)
          if data["ok"]?.try(&.as_bool)
            return data["result"]?
          end
        end

        nil
      end
    rescue ex
      Log.error { "Telegram API GET #{method} error: #{ex.message}" }
      nil
    end

    private def read_limited_io(io : IO, max_size : Int32) : String
      buffer = IO::Memory.new
      bytes_read = 0
      chunk = Bytes.new(READ_CHUNK_SIZE)

      while (n = io.read(chunk)) > 0
        bytes_read += n
        if bytes_read > max_size
          buffer.write(chunk[0, Math.max(0, max_size - (bytes_read - n))])
          buffer << "\n... (truncated)"
          # drain to EOF so the child never blocks on a full pipe
          while io.read(chunk) > 0
          end
          break
        end
        buffer.write(chunk[0, n])
      end

      buffer.to_s
    rescue
      ""
    end

    private def send_reply(chat_id : String, text : String) : Nil
      api_request("sendMessage", {
        "chat_id"    => chat_id,
        "text"       => text,
        "parse_mode" => "HTML",
      })
    end

    private def handle_command_message(msg : JSON::Any, sender : Sender) : Bool
      text = msg["text"]?.try(&.as_s)
      return false unless text && text.starts_with?('/')
      handle_command(text, sender[:chat_id], sender[:sender_id], sender[:first_name]) if command_for_me?(text, msg, sender)
      true
    end

    private def command_for_me?(text : String, msg : JSON::Any, sender : Sender) : Bool
      target = text.split(' ', 2)[0].split('@', 2)[1]?
      if target && !target.empty?
        return target.compare(@bot_username, case_insensitive: true) == 0
      end
      addressed?(msg, sender)
    end

    private def addressed?(msg : JSON::Any, sender : Sender) : Bool
      return true unless sender[:is_group]
      return true if (topic = sender[:topic]) && @topics.includes?(topic)
      mentioned?(msg)
    end

    private def chat_params(chat_id : String) : Hash(String, String)
      chat, _, topic = chat_id.partition(TOPIC_SEPARATOR)
      params = {"chat_id" => chat}
      params["message_thread_id"] = topic unless topic.empty? || topic == GENERAL_TOPIC.to_s
      params
    end

    private def mentioned?(msg : JSON::Any) : Bool
      return false unless regex = bot_mention_regex

      if text = msg["text"]?.try(&.as_s)
        return true if regex.matches?(text)
      end
      if caption = msg["caption"]?.try(&.as_s)
        return true if regex.matches?(caption)
      end

      if reply_username = msg.dig?("reply_to_message", "from", "username").try(&.as_s)
        return true if reply_username.compare(@bot_username, case_insensitive: true) == 0
      end

      false
    end

    # Telegram usernames are case-insensitive; match the mention as a whole
    # token so "@bot" does not also fire on "@bot_staging".
    private def bot_mention_regex : Regex?
      return nil if @bot_username.empty?
      @bot_mention_regex ||= /@#{Regex.escape(@bot_username)}\b/i
    end

    CHAT_LOG_MAX_BYTES  = 64_000
    CHAT_LOG_KEEP_LINES =    100

    private def record_chat_log(chat_id : String, sender_name : String, text : String) : Nil
      workspace = @session_manager.try(&.sessions_dir.parent) || Path["."]
      log_dir = workspace / "data" / "chat_logs"
      Dir.mkdir_p(log_dir)
      log_path = (log_dir / "telegram_#{chat_id}.log").to_s

      @chat_log_mutex.synchronize do
        timestamp = Time.local.to_s("%Y-%m-%d %H:%M:%S")
        File.open(log_path, "a") do |file|
          file.puts("[#{timestamp}] #{sender_name}: #{text}")
        end

        prune_chat_log(log_path)
      end
    rescue ex
      Log.error { "Error writing to chat log: #{ex.message}" }
    end

    # Rewrites the log only once it grows past the byte cap, so the common
    # append path costs a single write plus a cheap size check rather than
    # reading the whole file on every message.
    private def prune_chat_log(log_path : String) : Nil
      return if File.size(log_path) <= CHAT_LOG_MAX_BYTES

      lines = File.read_lines(log_path)
      return if lines.size <= CHAT_LOG_KEEP_LINES

      File.write(log_path, lines.last(CHAT_LOG_KEEP_LINES).join("\n") + "\n")
    end
  end
end
