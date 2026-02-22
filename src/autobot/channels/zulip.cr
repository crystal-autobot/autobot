require "crest"
require "json"
require "./base"

module Autobot::Channels
  # Zulip channel using Real-time Events API (Long Polling).
  #
  # Supports:
  # - Direct messages (private)
  # - Allowlisting senders by email
  class ZulipChannel < Channel
    Log = ::Log.for("channels.zulip")

    # The queue registered with Zulip.
    @queue_id : String? = nil

    # The last event read.
    @last_event_id : Int64 = -1

    # Request timeout. The server should supply this.
    @longpoll_timeout : Int64 = 90

    def initialize(
      bus : Bus::MessageBus,
      @site : String,
      @email : String,
      @api_key : String,
      allow_from : Array(String) = [] of String,
    )
      super("zulip", bus, allow_from)
      @site = @site.rstrip('/')
    end

    def start : Nil
      if @site.empty? || @email.empty? || @api_key.empty?
        Log.error { "Zulip configuration incomplete" }
        return
      end

      @running = true
      Log.info { "Starting Zulip channel for #{@email} at #{@site}..." }

      while @running
        begin
          unless @queue_id
            register_queue
          end

          poll_events
        rescue ex : Crest::RequestFailed
          Log.error { "Zulip request failed: #{ex.message} - #{ex.response.try(&.body)}" }
          @queue_id = nil # Force re-registration
          sleep 5.seconds if @running
        rescue ex
          Log.error { "Zulip error: #{ex.message}" }
          @queue_id = nil # Force re-registration
          sleep 5.seconds if @running
        end
      end
    end

    def stop : Nil
      @running = false
    end

    private def access_denied_message(sender_id : String) : String
      if @allow_from.empty?
        "This bot has no authorized users yet.\n" \
        "Add your user ID to <code>allow_from</code> in config.yml to get started.\n\n" \
        "Your ID: <code>#{sender_id}</code>"
      else
        "Access denied. You are not in the authorized users list."
      end
    end

    def send_message(message : Bus::OutboundMessage) : Nil
      params = {
        "type"    => "private",
        "to"      => message.chat_id,
        "content" => message.content,
      }

      begin
        response = Crest.post(
          "#{@site}/api/v1/messages",
          headers: {"Authorization" => auth_header},
          form: params
        )
        unless response.success?
          Log.error { "Failed to send Zulip message: #{response.body}" }
        end
      rescue ex
        Log.error { "Error sending Zulip message: #{ex.message}" }
      end
    end

    private def auth_header
      "Basic " + Base64.strict_encode("#{@email}:#{@api_key}")
    end

    private def register_queue
      response = Crest.post(
        "#{@site}/api/v1/register",
        headers: {"Authorization" => auth_header},
        form: {
          "event_types"       => ["message"].to_json,
          "fetch_event_types" => ["message", "realm"].to_json,
        }
      )

      if response.success?
        data = JSON.parse(response.body)
        @queue_id = data["queue_id"].as_s
        @last_event_id = data["last_event_id"].as_i64
        @longpoll_timeout = data["event_queue_longpoll_timeout_seconds"].as_i64
        Log.info { "Zulip queue registered: #{@queue_id}" }
      else
        raise "Failed to register Zulip queue: #{response.body}"
      end
    end

    private def poll_events
      return unless queue_id = @queue_id

      response = Crest.get(
        "#{@site}/api/v1/events",
        headers: {"Authorization" => auth_header},
        params: {
          "queue_id"      => queue_id,
          "last_event_id" => @last_event_id.to_s,
          "dont_block"    => "false",
        },
        read_timeout: @longpoll_timeout.seconds
      )

      if response.success?
        data = JSON.parse(response.body)
        events = data["events"].as_a
        events.each do |event|
          event_id = event["id"].as_i64
          @last_event_id = event_id if event_id > @last_event_id
          process_event(event)
        end
      elsif response.status == 400
        # Might mean queue expired
        Log.warn { "Zulip queue expired or invalid, re-registering..." }
        @queue_id = nil
      else
        Log.error { "Zulip poll error: #{response.status} #{response.body}" }
        sleep 5.seconds if @running
      end
    end

    private def process_event(event)
      return unless event["type"] == "message"
      message = event["message"]

      # We only support direct messages (private) for now
      return unless message["type"] == "private"

      sender_email = message["sender_email"].as_s
      return if sender_email == @email # Don't respond to self

      content = message["content"].as_s

      unless allowed?(sender_email)
        Log.warn { "Access denied for sender #{sender_email} on zulip. Add to allow_from to grant access." }
        send_message(Bus::OutboundMessage.new("zulip", sender_email, access_denied_message(sender_email)))
        return
      end
      Log.debug { "Zulip DM from #{sender_email}: #{content}" }

      handle_message(
        sender_id: sender_email,
        chat_id: sender_email, # For DMs, chat_id is the sender's email to reply back
        content: content
      )
    end
  end
end
