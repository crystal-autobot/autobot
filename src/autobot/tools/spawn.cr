require "./base"
require "../agent/subagent"
require "./result"

module Autobot
  module Tools
    # Tool to spawn a subagent for background task execution.
    #
    # The subagent runs in a fiber and announces its result back
    # to the main agent when complete.
    class SpawnTool < Tool
      @manager : Agent::SubagentManager
      @origin_channel : String = "cli"
      @origin_chat_id : String = "direct"

      def initialize(@manager : Agent::SubagentManager)
      end

      # Set the origin context for subagent announcements.
      def set_context(channel : String, chat_id : String) : Nil
        @origin_channel = channel
        @origin_chat_id = chat_id
      end

      def name : String
        "spawn"
      end

      def description : String
        "Spawn a subagent to handle a task in the background. " \
        "Use this for complex or time-consuming tasks that can run independently. " \
        "The subagent will complete the task and report back when done."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "task" => PropertySchema.new(
              type: "string",
              description: "The task for the subagent to complete"
            ),
            "label" => PropertySchema.new(
              type: "string",
              description: "Optional short label for the task (for display)"
            ),
          },
          required: ["task"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        task = params["task"].as_s
        label = params["label"]?.try(&.as_s)

        result = @manager.spawn(
          task: task,
          label: label,
          origin_channel: @origin_channel,
          origin_chat_id: @origin_chat_id
        )

        ToolResult.success(result)
      end
    end
  end
end
