require "./plugin"
require "../tools/result"

module Autobot
  module Plugins
    # Custom plugin to query rolling chat logs.
    class ChatLogPlugin < Plugin
      def name : String
        "chat_log"
      end

      def description : String
        "Consult the recent rolling chat log of a group chat"
      end

      def version : String
        "0.1.0"
      end

      def setup(context : PluginContext) : Nil
        context.tool_registry.register(ChatLogTool.new(context.workspace))
      end
    end

    # Custom tool to read recent rolling chat logs.
    class ChatLogTool < Tools::Tool
      DEFAULT_LIMIT =  50
      MIN_LIMIT     =   1
      MAX_LIMIT     = 100

      @workspace : Path

      def initialize(@workspace : Path)
      end

      def name : String
        "get_recent_chat_log"
      end

      def description : String
        "Retrieves the recent rolling chat logs for a group chat. Use this tool when you need to consult the context of recent discussions in the group. Pass the chat_id from the Current Session block in your system prompt."
      end

      def parameters : Tools::ToolSchema
        Tools::ToolSchema.new(
          properties: {
            "chat_id" => Tools::PropertySchema.new(
              type: "string",
              description: "The Telegram Chat ID/Group ID (e.g. '-1002549279967') to read logs for. Obtain this from the Current Session block in your system prompt."
            ),
            "limit" => Tools::PropertySchema.new(
              type: "integer",
              description: "Number of recent lines to retrieve (default: #{DEFAULT_LIMIT}, max: #{MAX_LIMIT})",
              minimum: MIN_LIMIT.to_i64,
              maximum: MAX_LIMIT.to_i64,
              default_value: DEFAULT_LIMIT.to_s
            ),
          },
          required: ["chat_id"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
        chat_id = params["chat_id"].as_s

        limit = (params["limit"]?.try(&.as_i?) || DEFAULT_LIMIT).clamp(MIN_LIMIT, MAX_LIMIT)

        # Prevent directory traversal
        unless chat_id.match(/^[a-zA-Z0-9_@-]+$/)
          return Tools::ToolResult.error("Invalid chat_id format. Must only contain alphanumeric characters, underscores, hyphens, and optional '@'.")
        end

        log_path = @workspace / "data" / "chat_logs" / "telegram_#{chat_id}.log"

        unless File.exists?(log_path.to_s)
          return Tools::ToolResult.success("No recent chat logs found for chat ID #{chat_id}.")
        end

        begin
          lines = File.read_lines(log_path.to_s)
          recent_lines = lines.size > limit ? lines[-limit..] : lines
          content = "### Recent Chat Logs for Chat #{chat_id}\n\n" + recent_lines.join("\n")
          Tools::ToolResult.success(content)
        rescue ex
          Tools::ToolResult.error("Error reading chat logs: #{ex.message}")
        end
      end
    end
  end
end
