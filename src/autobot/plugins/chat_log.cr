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
              description: "Number of recent lines to retrieve (default: 50, max: 100)",
              default_value: "50"
            ),
          },
          required: ["chat_id"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
        chat_id = params["chat_id"].as_s

        limit_val = params["limit"]?
        limit = 50
        if limit_val
          if val_i = limit_val.as_i?
            limit = val_i
          elsif val_s = limit_val.as_s?
            limit = val_s.to_i? || 50
          end
        end
        limit = 100 if limit > 100

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
