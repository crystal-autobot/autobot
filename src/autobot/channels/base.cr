require "../bus/events"
require "../bus/queue"

module Autobot::Channels
  # Abstract base class for chat channel integrations.
  #
  # Each channel (Telegram, Slack, etc.) should inherit from this class
  # and implement the `start`, `stop`, and `send_message` methods.
  abstract class Channel
    Log = ::Log.for("channels")

    getter name : String
    getter? running : Bool = false

    def initialize(@name : String, @bus : Bus::MessageBus, @allow_from : Array(String) = [] of String)
    end

    # Start the channel and begin listening for messages.
    abstract def start : Nil

    # Stop the channel and clean up resources.
    abstract def stop : Nil

    # Send an outbound message through this channel.
    abstract def send_message(message : Bus::OutboundMessage) : Nil

    # Check if a sender is allowed to use this bot.
    # Returns false if no allow list (deny by default).
    # Use ["*"] in allow_from to allow all senders.
    def allowed?(sender_id : String) : Bool
      return false if @allow_from.empty?
      return true if @allow_from.includes?("*")

      sender_str = sender_id.to_s
      return true if sender_str.in?(@allow_from)

      # Support pipe-delimited multi-part IDs (e.g. "12345|username")
      if sender_str.includes?('|')
        sender_str.split('|').each do |part|
          return true if part.presence && part.in?(@allow_from)
        end
      end

      false
    end

    # Handle an incoming message from the chat platform.
    # Checks permissions and forwards to the message bus.
    protected def handle_message(
      sender_id : String,
      chat_id : String,
      content : String,
      media : Array(Bus::MediaAttachment)? = nil,
      metadata : Hash(String, String) = {} of String => String,
    ) : Nil
      unless allowed?(sender_id)
        Log.warn { "Access denied for sender #{sender_id} on #{@name}. Add to allow_from to grant access." }
        return
      end

      message = Bus::InboundMessage.new(
        channel: @name,
        sender_id: sender_id,
        chat_id: chat_id,
        content: content,
        media: media,
        metadata: metadata,
      )

      @bus.publish_inbound(message)
    end
  end
end
