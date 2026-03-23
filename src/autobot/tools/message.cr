require "../bus/events"
require "./result"
require "./sandbox_executor"

module Autobot
  module Tools
    # Callback type for sending outbound messages.
    alias SendCallback = Bus::OutboundMessage -> Nil

    # Tool for sending messages to users on chat channels.
    #
    # Integrates with the message bus to deliver messages back to the
    # originating channel/chat. Context (channel + chat_id) is set
    # per-conversation so the LLM doesn't need to specify targets.
    #
    # Supports optional file attachments via `file_path` for sending
    # media (images, GIFs, documents) from the workspace.
    class MessageTool < Tool
      Log = ::Log.for("tools.message")

      MEDIA_TYPES = {
        ".jpg"  => {"photo", "image/jpeg"},
        ".jpeg" => {"photo", "image/jpeg"},
        ".png"  => {"photo", "image/png"},
        ".webp" => {"photo", "image/webp"},
        ".bmp"  => {"photo", "image/bmp"},
        ".gif"  => {"animation", "image/gif"},
        ".mp4"  => {"video", "video/mp4"},
        ".pdf"  => {"document", "application/pdf"},
      }

      @send_callback : SendCallback?
      @default_channel : String
      @default_chat_id : String
      @last_sent_content : String?

      def initialize(
        @executor : SandboxExecutor? = nil,
        @send_callback : SendCallback? = nil,
        @default_channel : String = "",
        @default_chat_id : String = "",
      )
      end

      # Content of the last successfully sent message (used by cron to save to session).
      getter last_sent_content : String?

      def clear_last_sent : Nil
        @last_sent_content = nil
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
        "Send a message to the user. Use this when you want to communicate something. " \
        "Supports optional file attachments (images, GIFs, documents) via file_path."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "content"   => PropertySchema.new(type: "string", description: "The message content to send"),
            "file_path" => PropertySchema.new(type: "string", description: "Optional: path to a file in the workspace to attach (image, GIF, document)"),
            "channel"   => PropertySchema.new(type: "string", description: "Optional: target channel (telegram, slack, etc.)"),
            "chat_id"   => PropertySchema.new(type: "string", description: "Optional: target chat/user ID"),
          },
          required: ["content"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        content = params["content"].as_s
        channel = params["channel"]?.try(&.as_s) || @default_channel
        chat_id = params["chat_id"]?.try(&.as_s) || @default_chat_id

        if channel.empty? || chat_id.empty?
          return ToolResult.error("No target channel/chat specified")
        end

        callback = @send_callback
        unless callback
          return ToolResult.error("Message sending not configured")
        end

        media = build_media_attachment(params["file_path"]?.try(&.as_s))
        return media if media.is_a?(ToolResult)

        msg = Bus::OutboundMessage.new(
          channel: channel,
          chat_id: chat_id,
          content: content,
          media: media,
        )

        callback.call(msg)
        @last_sent_content = content

        if media
          Log.info { "Message sent to #{channel}:#{chat_id} with attachment" }
        else
          Log.info { "Message sent to #{channel}:#{chat_id}" }
        end
        ToolResult.success("Message sent to #{channel}:#{chat_id}")
      rescue ex
        ToolResult.error("Error sending message: #{ex.message}")
      end

      private def build_media_attachment(file_path : String?) : Array(Bus::MediaAttachment)? | ToolResult
        return nil unless file_path

        executor = @executor
        return ToolResult.error("File attachments not available (no sandbox executor)") unless executor

        result = executor.read_file_base64(file_path)
        return ToolResult.error("Cannot read file: #{result.content}") unless result.success?

        ext = File.extname(file_path).downcase
        media_type, mime_type = MEDIA_TYPES[ext]? || {"document", "application/octet-stream"}

        Log.info { "Attaching file: #{file_path} (#{media_type}, #{mime_type})" }

        [Bus::MediaAttachment.new(
          type: media_type,
          file_path: file_path,
          mime_type: mime_type,
          data: result.content,
        )]
      end
    end
  end
end
