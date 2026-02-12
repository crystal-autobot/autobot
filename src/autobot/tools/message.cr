require "../bus/events"

module Autobot
  module Tools
    # Callback type for sending outbound messages.
    alias SendCallback = Bus::OutboundMessage -> Nil

    # Tool for sending messages to users on chat channels.
    #
    # Integrates with the message bus to deliver messages back to the
    # originating channel/chat. Context (channel + chat_id) is set
    # per-conversation so the LLM doesn't need to specify targets.
    class MessageTool < Tool
      @send_callback : SendCallback?
      @default_channel : String
      @default_chat_id : String

      def initialize(
        @send_callback : SendCallback? = nil,
        @default_channel : String = "",
        @default_chat_id : String = "",
      )
      end

      # Set the current message context (called when processing a new inbound message).
      def set_context(channel : String, chat_id : String) : Nil
        @default_channel = channel
        @default_chat_id = chat_id
      end

      # Set the callback for sending messages via the bus.
      def send_callback=(callback : SendCallback) : Nil
        @send_callback = callback
      end

      def name : String
        "message"
      end

      def description : String
        "Send a message to the user. Use this when you want to communicate something."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "content" => PropertySchema.new(type: "string", description: "The message content to send"),
            "channel" => PropertySchema.new(type: "string", description: "Optional: target channel (telegram, slack, etc.)"),
            "chat_id" => PropertySchema.new(type: "string", description: "Optional: target chat/user ID"),
          },
          required: ["content"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : String
        content = params["content"].as_s
        channel = params["channel"]?.try(&.as_s) || @default_channel
        chat_id = params["chat_id"]?.try(&.as_s) || @default_chat_id

        if channel.empty? || chat_id.empty?
          return "Error: No target channel/chat specified"
        end

        callback = @send_callback
        unless callback
          return "Error: Message sending not configured"
        end

        msg = Bus::OutboundMessage.new(
          channel: channel,
          chat_id: chat_id,
          content: content
        )

        callback.call(msg)
        "Message sent to #{channel}:#{chat_id}"
      rescue ex
        "Error sending message: #{ex.message}"
      end
    end
  end
end
