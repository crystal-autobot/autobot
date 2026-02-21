require "base64"
require "http/client"
require "http_proxy"
require "json"
require "uri"
require "./base"

module Autobot::Channels
  # Converts Markdown to Telegram-safe HTML.
  #
  # Telegram supports: <b>, <i>, <u>, <s>, <code>, <pre>, <a>, <blockquote>
  # All <, >, & outside tags must be escaped. Code/pre cannot contain other tags.
  module MarkdownToTelegramHTML
    TELEGRAM_MAX_LENGTH = 4096

    CODE_BLOCK_PREFIX  = "\x00CB"
    INLINE_CODE_PREFIX = "\x00IC"
    UNDERSCORE_PREFIX  = "\x00US"
    HEADER_PREFIX      = "\x00HD"
    SUFFIX             = "\x00"

    HEADER_REGEX     = Regex.new(%q(^#{1,6}\s+([^\n]+)$), Regex::Options::MULTILINE)
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
      headers = [] of String

      result = text
      result = extract_code_blocks(result, code_blocks)
      result = extract_inline_code(result, inline_codes)

      # Extract block elements (before HTML escape since > would be escaped)
      result = extract_headers(result, headers)
      result = result.gsub(BLOCKQUOTE_REGEX, "\\1")
      result = result.gsub(HR_REGEX, "")

      result = escape_html(result)
      result = protect_underscore_runs(result, underscore_runs)
      result = convert_inline_formatting(result)
      result = restore_underscore_runs(result, underscore_runs)
      result = restore_headers(result, headers)
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
      split_by_paragraphs(text)
    end

    private def self.extract_headers(text : String, store : Array(String)) : String
      text.gsub(HEADER_REGEX) do |_, match|
        store << "<b>#{escape_html(match[1])}</b>"
        "#{HEADER_PREFIX}#{store.size - 1}#{SUFFIX}"
      end
    end

    private def self.restore_headers(text : String, store : Array(String)) : String
      result = text
      store.each_with_index do |html, i|
        result = result.gsub("#{HEADER_PREFIX}#{i}#{SUFFIX}", html)
      end
      result
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

  # Manages a single streaming message update cycle for a Telegram chat.
  #
  # On the first delta, sends a placeholder message. Subsequent deltas are
  # accumulated and periodically pushed via `editMessageText` (throttled to
  # respect Telegram rate limits). The final formatted message is applied
  # by the channel's `send_message` after the LLM response completes.
  class TelegramStreamingSession
    EDIT_THROTTLE   = 1.second
    TRUNCATION_TAIL = "..."
    MAX_PLAIN_TEXT  = MarkdownToTelegramHTML::TELEGRAM_MAX_LENGTH - TRUNCATION_TAIL.size

    getter? active : Bool = true
    getter message_id : Int64? = nil

    def initialize(@chat_id : String, @api_caller : Proc(String, Hash(String, String), JSON::Any?))
      @accumulated = IO::Memory.new
      @last_edit = Time.utc - EDIT_THROTTLE
    end

    # Append a text delta from the LLM. Sends or edits the Telegram message
    # as appropriate.
    def on_delta(delta : String) : Nil
      return unless active?
      @accumulated.print(delta)

      if @message_id.nil?
        send_initial_message
      else
        edit_if_throttle_allows
      end
    end

    private def send_initial_message : Nil
      text = truncated_plain_text
      return if text.empty?

      result = @api_caller.call("sendMessage", {
        "chat_id" => @chat_id,
        "text"    => text,
      })
      if result
        @message_id = result["message_id"]?.try(&.as_i64?)
      end
      @last_edit = Time.utc
    end

    private def edit_if_throttle_allows : Nil
      now = Time.utc
      return if (now - @last_edit) < EDIT_THROTTLE

      msg_id = @message_id
      return unless msg_id

      @api_caller.call("editMessageText", {
        "chat_id"    => @chat_id,
        "message_id" => msg_id.to_s,
        "text"       => truncated_plain_text,
      })
      @last_edit = now
    end

    private def truncated_plain_text : String
      text = @accumulated.to_s
      if text.size > MAX_PLAIN_TEXT
        text[0, MAX_PLAIN_TEXT] + TRUNCATION_TAIL
      else
        text
      end
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
  # - Optional streaming (progressive message updates)
  class TelegramChannel < Channel
    Log = ::Log.for("channels.telegram")

    TELEGRAM_API_BASE = "https://api.telegram.org"
    POLL_TIMEOUT      =  30
    TYPING_INTERVAL   = 4.0
    MAX_IMAGE_SIZE    = 20 * 1024 * 1024 # 20 MB

    @offset : Int64 = 0_i64
    @bot_username : String = ""
    @typing_channels : Set(String) = Set(String).new
    @streaming_sessions : Hash(String, TelegramStreamingSession) = {} of String => TelegramStreamingSession

    def initialize(
      @bus : Bus::MessageBus,
      @token : String,
      @allow_from : Array(String) = [] of String,
      @proxy : String? = nil,
      @custom_commands : Config::CustomCommandsConfig = Config::CustomCommandsConfig.new,
      @session_manager : Session::Manager? = nil,
      @transcriber : Transcriber? = nil,
      @streaming_enabled : Bool = false,
    )
      super("telegram", @bus, @allow_from)
    end

    # Create a streaming callback for the given chat_id.
    # Returns nil if streaming is disabled.
    def create_stream_callback(chat_id : String) : Providers::StreamCallback?
      return nil unless @streaming_enabled

      api_caller = ->(method : String, params : Hash(String, String)) : JSON::Any? {
        api_request(method, params)
      }

      session = TelegramStreamingSession.new(chat_id, api_caller)
      @streaming_sessions[chat_id] = session

      Providers::StreamCallback.new { |delta| session.on_delta(delta) }
    end

    def start : Nil
      if @token.empty?
        Log.error { "Telegram bot token not configured" }
        return
      end

      @running = true

      if bot_info = api_request("getMe")
        if username = bot_info["username"]?.try(&.as_s)
          @bot_username = username
        end
        Log.info { "Telegram bot @#{@bot_username} connected" }
      end

      register_commands

      Log.info { "Starting Telegram bot (long polling)..." }
      poll_updates
    end

    def stop : Nil
      @running = false
      @typing_channels.clear
    end

    def send_message(message : Bus::OutboundMessage) : Nil
      stop_typing(message.chat_id)

      html = MarkdownToTelegramHTML.convert(message.content)
      html = MarkdownToTelegramHTML.strip_html(html) unless MarkdownToTelegramHTML.valid_html?(html)

      streaming_session = @streaming_sessions.delete(message.chat_id)
      if streaming_session && (msg_id = streaming_session.message_id)
        finalize_streaming_message(message.chat_id, msg_id, html)
      else
        MarkdownToTelegramHTML.split_message(html).each do |chunk|
          send_html_chunk(message.chat_id, chunk)
        end
      end
    end

    private def finalize_streaming_message(chat_id : String, message_id : Int64, html : String) : Nil
      chunks = MarkdownToTelegramHTML.split_message(html)

      # Edit the existing streamed message with the first (formatted) chunk
      first_chunk = chunks.first
      result = api_request("editMessageText", {
        "chat_id"    => chat_id,
        "message_id" => message_id.to_s,
        "text"       => first_chunk,
        "parse_mode" => "HTML",
      })

      # Fallback to plain text if HTML edit fails
      unless result
        Log.warn { "HTML edit failed for streaming message, falling back to plain text" }
        api_request("editMessageText", {
          "chat_id"    => chat_id,
          "message_id" => message_id.to_s,
          "text"       => MarkdownToTelegramHTML.strip_html(first_chunk),
        })
      end

      # Send remaining chunks as new messages
      chunks.skip(1).each do |chunk|
        send_html_chunk(chat_id, chunk)
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

      if text = msg["text"]?.try(&.as_s)
        if text.starts_with?('/')
          handle_command(text, sender[:chat_id], sender[:sender_id], sender[:first_name])
          return
        end
      end

      unless allowed?(sender[:sender_id])
        Log.warn { "Access denied for sender #{sender[:sender_id]} on telegram. Add to allow_from to grant access." }
        send_reply(sender[:chat_id], access_denied_message(sender[:sender_id]))
        return
      end

      content, media_attachments = build_content_and_media(msg)

      Log.debug { "Message from #{sender[:sender_id]}: #{content}" }

      start_typing(sender[:chat_id])

      handle_message(
        sender_id: sender[:sender_id],
        chat_id: sender[:chat_id],
        content: content,
        media: media_attachments.empty? ? nil : media_attachments,
        metadata: build_metadata(msg, sender),
      )
    rescue ex
      Log.error { "Error processing message: #{ex.message}" }
    end

    private def extract_sender(msg : JSON::Any) : NamedTuple(chat_id: String, user_id: String, username: String?, first_name: String, sender_id: String, is_group: Bool)?
      chat = msg["chat"]?
      from = msg["from"]?
      return nil unless chat && from

      chat_id = chat["id"].as_i64.to_s
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
      }
    end

    private def build_content_and_media(msg : JSON::Any) : {String, Array(Bus::MediaAttachment)}
      content_parts = [] of String
      media_attachments = [] of Bus::MediaAttachment

      if text = msg["text"]?.try(&.as_s)
        content_parts << text
      end
      if caption = msg["caption"]?.try(&.as_s)
        content_parts << caption
      end

      append_media_attachments(msg, content_parts, media_attachments)

      content = content_parts.empty? ? "[empty message]" : content_parts.join("\n")
      {content, media_attachments}
    end

    private def append_media_attachments(msg : JSON::Any, content_parts : Array(String), media_attachments : Array(Bus::MediaAttachment)) : Nil
      append_photo_attachment(msg, content_parts, media_attachments)
      append_voice_attachment(msg, content_parts, media_attachments)
      append_audio_attachment(msg, content_parts, media_attachments)
      append_document_attachment(msg, content_parts, media_attachments)
    end

    private def append_photo_attachment(msg : JSON::Any, content_parts : Array(String), media_attachments : Array(Bus::MediaAttachment)) : Nil
      if photos = msg["photo"]?.try(&.as_a?)
        if last_photo = photos.last?
          file_id = last_photo["file_id"].as_s
          image_data = download_telegram_file(file_id)
          media_attachments << Bus::MediaAttachment.new(
            type: "photo", url: file_id, mime_type: "image/jpeg", data: image_data,
          )
          content_parts << "[photo]" if content_parts.empty?
        end
      end
    end

    private def download_telegram_file(file_id : String) : String?
      bytes = download_telegram_file_bytes(file_id)
      return nil unless bytes

      Base64.strict_encode(bytes)
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

      uri = URI.parse(TELEGRAM_API_BASE)
      client = HTTP::Client.new(uri)
      apply_proxy(client)

      response = client.get("/file/bot#{@token}/#{file_path}")
      client.close

      if response.status_code == 200
        response.body.to_slice.dup
      else
        Log.warn { "Failed to download file: HTTP #{response.status_code}" }
        nil
      end
    rescue ex
      Log.error { "Error downloading telegram file: #{ex.message}" }
      nil
    end

    private def apply_proxy(client : HTTP::Client) : Nil
      proxy_url = @proxy
      return unless proxy_url

      uri = URI.parse(proxy_url)
      host = uri.host
      return unless host

      client.proxy = HTTP::Proxy::Client.new(host, uri.port || 8080)
    end

    private def transcribe_file(file_id : String) : String?
      transcriber = @transcriber
      return nil unless transcriber

      bytes = download_telegram_file_bytes(file_id)
      return nil unless bytes

      transcriber.transcribe(bytes)
    end

    private def append_voice_attachment(msg : JSON::Any, content_parts : Array(String), media_attachments : Array(Bus::MediaAttachment)) : Nil
      if voice = msg["voice"]?
        file_id = voice["file_id"].as_s
        media_attachments << Bus::MediaAttachment.new(type: "voice", url: file_id, mime_type: voice["mime_type"]?.try(&.as_s) || "audio/ogg")

        if content_parts.empty?
          text = transcribe_file(file_id)
          content_parts << (text ? "[voice transcription]: #{text}" : "[voice message]")
        end
      end
    end

    private def append_audio_attachment(msg : JSON::Any, content_parts : Array(String), media_attachments : Array(Bus::MediaAttachment)) : Nil
      if audio = msg["audio"]?
        file_id = audio["file_id"].as_s
        media_attachments << Bus::MediaAttachment.new(type: "voice", url: file_id, mime_type: audio["mime_type"]?.try(&.as_s) || "audio/mpeg")

        if content_parts.empty?
          title = audio["title"]?.try(&.as_s) || "audio"
          text = transcribe_file(file_id)
          content_parts << (text ? "[voice transcription]: #{text}" : "[audio: #{title}]")
        end
      end
    end

    private def append_document_attachment(msg : JSON::Any, content_parts : Array(String), media_attachments : Array(Bus::MediaAttachment)) : Nil
      if doc = msg["document"]?
        file_id = doc["file_id"].as_s
        file_name = doc["file_name"]?.try(&.as_s) || "unknown"
        media_attachments << Bus::MediaAttachment.new(type: "document", url: file_id, mime_type: doc["mime_type"]?.try(&.as_s))
        content_parts << "[document: #{file_name}]" if content_parts.empty?
      end
    end

    private def build_metadata(msg : JSON::Any, sender : NamedTuple(chat_id: String, user_id: String, username: String?, first_name: String, sender_id: String, is_group: Bool)) : Hash(String, String)
      {
        "message_id" => msg["message_id"].as_i64.to_s,
        "user_id"    => sender[:user_id],
        "username"   => sender[:username] || "",
        "first_name" => sender[:first_name],
        "is_group"   => sender[:is_group].to_s,
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

    private def send_help(chat_id : String) : Nil
      lines = [
        "<b>Autobot commands</b>\n",
        "/start - Start the bot",
        "/reset - Reset conversation history",
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
      end
    end

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

      # Read with size limit to prevent DoS (truncate at 4000 chars)
      output = read_limited_io(process.output, 4000)
      error_output = read_limited_io(process.error, 4000)
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
      current_arg = ""
      in_quotes = false
      quote_char = '\0'
      escaped = false

      args_str.each_char do |char|
        if escaped
          current_arg += char.to_s
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
              current_arg += char.to_s
            end
          else
            in_quotes = true
            quote_char = char
          end
        when ' ', '\t'
          if in_quotes
            current_arg += char.to_s
          else
            unless current_arg.empty?
              args << current_arg
              current_arg = ""
            end
          end
        else
          current_arg += char.to_s
        end
      end

      unless current_arg.empty?
        args << current_arg
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

    private def api_request(method : String, params : Hash(String, String) = {} of String => String) : JSON::Any?
      url = "#{TELEGRAM_API_BASE}/bot#{@token}/#{method}"
      response = HTTP::Client.post(url, form: URI::Params.encode(params))

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
      uri = URI.parse(TELEGRAM_API_BASE)
      client = HTTP::Client.new(uri)
      client.read_timeout = (POLL_TIMEOUT + 10).seconds

      query = URI::Params.encode(params)
      response = client.get("/bot#{@token}/#{method}?#{query}")
      client.close

      if response.status_code == 200
        data = JSON.parse(response.body)
        if data["ok"]?.try(&.as_bool)
          return data["result"]?
        end
      end

      nil
    rescue ex
      Log.error { "Telegram API GET #{method} error: #{ex.message}" }
      nil
    end

    private def read_limited_io(io : IO, max_size : Int32) : String
      buffer = IO::Memory.new
      bytes_read = 0
      chunk = Bytes.new(4096)

      while (n = io.read(chunk)) > 0
        bytes_read += n
        if bytes_read > max_size
          buffer.write(chunk[0, Math.max(0, max_size - (bytes_read - n))])
          buffer << "\n... (truncated)"
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
  end
end
