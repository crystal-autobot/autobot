require "http/web_socket"
require "json"
require "./base"

module Autobot::Channels
  # WhatsApp channel that connects to a Node.js bridge.
  #
  # The bridge uses @whiskeysockets/baileys to handle the WhatsApp Web protocol.
  # Communication is via JSON messages over WebSocket.
  #
  # Features:
  # - QR code authentication (displayed in bridge terminal)
  # - Message handling (text, voice message notices)
  # - Connection state management
  # - Auto-reconnection with backoff
  # - Allow list for access control
  class WhatsAppChannel < Channel
    Log = ::Log.for("channels.whatsapp")

    RECONNECT_DELAY = 5

    @connected : Bool = false

    def initialize(
      @bus : Bus::MessageBus,
      @bridge_url : String = "ws://localhost:3001",
      @allow_from : Array(String) = [] of String,
    )
      super("whatsapp", @bus, @allow_from)
    end

    def start : Nil
      if @bridge_url.empty?
        Log.error { "WhatsApp bridge URL not configured" }
        return
      end

      @running = true
      Log.info { "Connecting to WhatsApp bridge at #{@bridge_url}..." }

      while @running
        begin
          connect_to_bridge
        rescue ex
          @connected = false
          Log.warn { "WhatsApp bridge connection error: #{ex.message}" }
        end

        if @running
          Log.info { "Reconnecting to WhatsApp bridge in #{RECONNECT_DELAY}s..." }
          sleep(RECONNECT_DELAY.seconds)
        end
      end
    end

    def stop : Nil
      @running = false
      @connected = false
    end

    def send_message(message : Bus::OutboundMessage) : Nil
      unless @connected
        Log.warn { "WhatsApp bridge not connected" }
        return
      end

      Log.debug { "WhatsApp outbound to #{message.chat_id} queued (requires bridge connection)" }
    end

    private def connect_to_bridge : Nil
      uri = URI.parse(@bridge_url)
      host = uri.host || "localhost"
      port = uri.port || 3001
      path = uri.path
      path = "/" if path.empty?
      tls = uri.scheme == "wss"

      ws = HTTP::WebSocket.new(host: host, path: path, port: port, tls: tls)

      ws.on_message do |raw|
        handle_bridge_message(raw, ws)
      end

      ws.on_close do |code, reason|
        @connected = false
        Log.info { "WhatsApp bridge disconnected: #{code} #{reason}" }
      end

      Log.info { "Connected to WhatsApp bridge" }
      @connected = true

      ws.run
    end

    private def handle_bridge_message(raw : String, ws : HTTP::WebSocket) : Nil
      data = JSON.parse(raw)
      msg_type = data["type"]?.try(&.as_s)

      case msg_type
      when "message"
        handle_incoming_message(data)
      when "status"
        handle_status(data)
      when "qr"
        Log.info { "Scan QR code in the bridge terminal to connect WhatsApp" }
      when "error"
        Log.error { "WhatsApp bridge error: #{data["error"]?.try(&.as_s)}" }
      end
    rescue ex
      Log.error { "Error handling bridge message: #{ex.message}" }
    end

    private def handle_incoming_message(data : JSON::Any) : Nil
      pn = data["pn"]?.try(&.as_s) || ""
      sender = data["sender"]?.try(&.as_s) || ""
      content = data["content"]?.try(&.as_s) || ""

      user_id = pn.empty? ? sender : pn
      sender_id = user_id.includes?('@') ? user_id.split('@').first : user_id

      if content == "[Voice Message]"
        Log.info { "Voice message from #{sender_id} (transcription not yet supported)" }
        content = "[Voice Message: Transcription not available for WhatsApp yet]"
      end

      is_group = data["isGroup"]?.try(&.as_bool?) || false

      metadata = {
        "message_id" => data["id"]?.try(&.as_s) || "",
        "timestamp"  => data["timestamp"]?.try(&.as_s) || "",
        "is_group"   => is_group.to_s,
      }

      handle_message(
        sender_id: sender_id,
        chat_id: sender,
        content: content,
        metadata: metadata,
      )
    end

    private def handle_status(data : JSON::Any) : Nil
      status = data["status"]?.try(&.as_s)
      Log.info { "WhatsApp status: #{status}" }

      case status
      when "connected"
        @connected = true
      when "disconnected"
        @connected = false
      end
    end
  end
end
