require "http/web_socket"
require "http/client"
require "json"
require "../constants"
require "./base"

module Autobot::Channels
  # Slack channel using Socket Mode (WebSocket).
  #
  # Features:
  # - Socket Mode (no webhook/public IP needed)
  # - DM handling with configurable policies
  # - App mention handling in channels
  # - Thread support (replies in threads for channel messages)
  # - Group/channel policies (open, mention, allowlist)
  # - Bot mention stripping
  # - Emoji reactions on received messages
  class SlackChannel < Channel
    Log = ::Log.for("channels.slack")

    SLACK_API_BASE         = "https://slack.com/api"
    RECONNECT_DELAY        = 5.seconds
    DEFAULT_REACTION_EMOJI = "eyes"

    @bot_user_id : String = ""

    def initialize(
      @bus : Bus::MessageBus,
      @bot_token : String,
      @app_token : String,
      allow_from : Array(String) = [] of String,
      @group_policy : String = "mention",
      @group_allow_from : Array(String) = [] of String,
      @dm_config : Config::SlackDMConfig = Config::SlackDMConfig.new,
    )
      super(Constants::CHANNEL_SLACK, @bus, allow_from)
    end

    def start : Nil
      if @bot_token.empty? || @app_token.empty?
        Log.error { "Slack bot/app token not configured" }
        return
      end

      @running = true
      resolve_bot_identity

      Log.info { "Starting Slack Socket Mode..." }

      while @running
        begin
          connect_socket_mode
        rescue ex
          Log.error { "Slack Socket Mode error: #{ex.message}" }
          sleep(RECONNECT_DELAY) if @running
        end
      end
    end

    def stop : Nil
      @running = false
    end

    def send_message(message : Bus::OutboundMessage) : Nil
      if message.media?.try(&.any? { |attachment| attachment.type == "photo" && attachment.data })
        Log.warn { "Image sending not yet supported for Slack" }
      end

      thread_ts = message.metadata["thread_ts"]?
      channel_type = message.metadata["channel_type"]?
      use_thread = !thread_ts.nil? && channel_type != "im"
      mrkdwn = MarkdownToSlackMrkdwn.convert(message.content)

      MarkdownToSlackMrkdwn.split_message(mrkdwn).each do |chunk|
        send_slack_message(message.chat_id, chunk, use_thread ? thread_ts : nil)
      end
    end

    private def send_slack_message(chat_id : String, text : String, thread_ts : String?) : Nil
      body = JSON.build do |json|
        json.object do
          json.field "channel", chat_id
          json.field "text", text
          if ts = thread_ts
            json.field "thread_ts", ts
          end
        end
      end

      response = slack_api("chat.postMessage", body)
      unless response
        Log.error { "Failed to send Slack message to #{chat_id}" }
      end
    end

    private def resolve_bot_identity : Nil
      response = slack_api("auth.test")
      return unless response

      data = JSON.parse(response)
      if data["ok"]?.try(&.as_bool)
        if user_id = data["user_id"]?.try(&.as_s)
          @bot_user_id = user_id
        end
        Log.info { "Slack bot connected as #{@bot_user_id}" }
      end
    rescue ex
      Log.warn { "Slack auth.test failed: #{ex.message}" }
    end

    private def connect_socket_mode : Nil
      response = slack_api_with_token("apps.connections.open", @app_token)
      return unless response

      data = JSON.parse(response)
      unless data["ok"]?.try(&.as_bool)
        Log.error { "Failed to open Slack connection: #{data["error"]?.try(&.as_s)}" }
        return
      end

      ws_url = data["url"]?.try(&.as_s)
      unless ws_url
        Log.error { "No WebSocket URL in Slack response" }
        return
      end

      uri = URI.parse(ws_url)
      host = uri.host
      return unless host

      path = uri.path
      if query = uri.query
        path = "#{path}?#{query}"
      end

      Log.info { "Connecting to Slack WebSocket..." }

      ws = HTTP::WebSocket.new(host: host, path: path, tls: true)

      ws.on_message do |raw|
        handle_socket_message(raw, ws)
      end

      ws.on_close do |code, reason|
        Log.info { "Slack WebSocket closed: #{code} #{reason}" }
      end

      ws.run
    end

    private def handle_socket_message(raw : String, ws : HTTP::WebSocket) : Nil
      data = JSON.parse(raw)
      acknowledge_envelope(data, ws)

      event = extract_socket_event(data)
      return unless event

      event_data = parse_socket_event(event)
      return unless event_data
      return if skip_socket_event?(event_data)

      text = strip_bot_mention(event_data[:text])

      if ts = event_data[:ts]
        spawn { add_reaction(event_data[:chat_id], ts, DEFAULT_REACTION_EMOJI) }
      end

      Log.debug { "Slack message from #{event_data[:sender_id]}: #{text}" }

      handle_message(
        sender_id: event_data[:sender_id],
        chat_id: event_data[:chat_id],
        content: text,
        metadata: {
          "thread_ts"    => event_data[:thread_ts],
          "channel_type" => event_data[:channel_type],
        },
      )
    rescue ex
      Log.error { "Error handling Slack event: #{ex.message}" }
    end

    private def acknowledge_envelope(data : JSON::Any, ws : HTTP::WebSocket) : Nil
      if envelope_id = data["envelope_id"]?.try(&.as_s)
        ws.send({envelope_id: envelope_id}.to_json)
      end
    end

    private def extract_socket_event(data : JSON::Any) : JSON::Any?
      return nil unless data["type"]?.try(&.as_s) == "events_api"
      payload = data["payload"]?
      return nil unless payload
      payload["event"]?
    end

    private def parse_socket_event(event : JSON::Any) : NamedTuple(event_type: String, sender_id: String, chat_id: String, text: String, channel_type: String, thread_ts: String, ts: String?)?
      event_type = event["type"]?.try(&.as_s)
      return nil unless event_type && (event_type == "message" || event_type == "app_mention")
      return nil if event["subtype"]?

      sender_id = event["user"]?.try(&.as_s)
      chat_id = event["channel"]?.try(&.as_s)
      return nil unless sender_id && chat_id

      text = event["text"]?.try(&.as_s) || ""
      channel_type = event["channel_type"]?.try(&.as_s) || ""
      ts = event["ts"]?.try(&.as_s)
      thread_ts = event["thread_ts"]?.try(&.as_s) || ts || ""

      {
        event_type:   event_type,
        sender_id:    sender_id,
        chat_id:      chat_id,
        text:         text,
        channel_type: channel_type,
        thread_ts:    thread_ts,
        ts:           ts,
      }
    end

    private def skip_socket_event?(event_data : NamedTuple(event_type: String, sender_id: String, chat_id: String, text: String, channel_type: String, thread_ts: String, ts: String?)) : Bool
      return true if !@bot_user_id.empty? && event_data[:sender_id] == @bot_user_id

      if event_data[:event_type] == "message" && !@bot_user_id.empty? && event_data[:text].includes?("<@#{@bot_user_id}>")
        return true
      end

      return true unless slack_allowed?(event_data[:sender_id], event_data[:chat_id], event_data[:channel_type])

      if event_data[:channel_type] != "im" && !should_respond_in_channel?(event_data[:event_type], event_data[:text], event_data[:chat_id])
        return true
      end

      false
    end

    private def slack_allowed?(sender_id : String, chat_id : String, channel_type : String) : Bool
      if channel_type == "im"
        return false unless @dm_config.enabled?
        if @dm_config.policy == "allowlist"
          return @dm_config.allow_from.includes?(sender_id)
        end
        return true
      end

      if @group_policy == "allowlist"
        return @group_allow_from.includes?(chat_id)
      end

      true
    end

    private def should_respond_in_channel?(event_type : String, text : String, chat_id : String) : Bool
      case @group_policy
      when "open"
        true
      when "mention"
        event_type == "app_mention" || (!@bot_user_id.empty? && text.includes?("<@#{@bot_user_id}>"))
      when "allowlist"
        @group_allow_from.includes?(chat_id)
      else
        false
      end
    end

    private def strip_bot_mention(text : String) : String
      return text if @bot_user_id.empty?
      text.gsub(/<@#{Regex.escape(@bot_user_id)}>\s*/, "").strip
    end

    private def add_reaction(channel : String, timestamp : String, emoji : String) : Nil
      body = JSON.build do |json|
        json.object do
          json.field "channel", channel
          json.field "name", emoji
          json.field "timestamp", timestamp
        end
      end

      slack_api("reactions.add", body)
    rescue ex
      Log.debug { "Slack reactions.add failed: #{ex.message}" }
    end

    private def slack_api(method : String, body : String? = nil) : String?
      slack_api_with_token(method, @bot_token, body)
    end

    private def slack_api_with_token(method : String, token : String, body : String? = nil) : String?
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{token}",
        "Content-Type"  => "application/json; charset=utf-8",
      }

      response = if body
                   HTTP::Client.post("#{SLACK_API_BASE}/#{method}", headers: headers, body: body)
                 else
                   HTTP::Client.post("#{SLACK_API_BASE}/#{method}", headers: headers)
                 end

      if response.status.ok?
        return response.body
      end

      Log.error { "Slack API #{method} HTTP #{response.status_code}" }
      nil
    rescue ex
      Log.error { "Slack API #{method} error: #{ex.message}" }
      nil
    end
  end
end
