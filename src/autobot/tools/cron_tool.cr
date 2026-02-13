require "./base"
require "../cron/service"
require "../cron/types"
require "./result"

module Autobot
  module Tools
    # Tool to schedule reminders and recurring tasks via the cron service.
    class CronTool < Tool
      @cron : Cron::Service
      @channel : String = ""
      @chat_id : String = ""

      def initialize(@cron : Cron::Service)
      end

      # Set the current session context for delivery.
      def set_context(channel : String, chat_id : String) : Nil
        @channel = channel
        @chat_id = chat_id
      end

      def name : String
        "cron"
      end

      def description : String
        "Schedule reminders and recurring tasks. Actions: add, list, remove."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "action" => PropertySchema.new(
              type: "string",
              enum_values: ["add", "list", "remove"],
              description: "Action to perform"
            ),
            "message" => PropertySchema.new(
              type: "string",
              description: "Reminder message (for add)"
            ),
            "every_seconds" => PropertySchema.new(
              type: "integer",
              description: "Interval in seconds (for recurring tasks)"
            ),
            "cron_expr" => PropertySchema.new(
              type: "string",
              description: "Cron expression like '0 9 * * *' (for scheduled tasks)"
            ),
            "at" => PropertySchema.new(
              type: "string",
              description: "ISO datetime for one-time execution (e.g. '2026-02-12T10:30:00')"
            ),
            "job_id" => PropertySchema.new(
              type: "string",
              description: "Job ID (for remove)"
            ),
          },
          required: ["action"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        action = params["action"].as_s

        case action
        when "add"
          add_job(params)
        when "list"
          list_jobs
        when "remove"
          remove_job(params)
        else
          ToolResult.error("Unknown action: #{action}")
        end
      end

      private def add_job(params : Hash(String, JSON::Any)) : ToolResult
        message = params["message"]?.try(&.as_s) || ""
        return ToolResult.error("message is required for add") if message.empty?
        return ToolResult.error("no session context (channel/chat_id)") if @channel.empty? || @chat_id.empty?

        every_seconds = params["every_seconds"]?.try(&.as_i64)
        cron_expr = params["cron_expr"]?.try(&.as_s)
        at = params["at"]?.try(&.as_s)

        delete_after = false
        schedule = if every_seconds
                     Cron::CronSchedule.new(kind: Cron::ScheduleKind::Every, every_ms: every_seconds * 1000)
                   elsif cron_expr
                     Cron::CronSchedule.new(kind: Cron::ScheduleKind::Cron, expr: cron_expr)
                   elsif at
                     dt = Time.parse_iso8601(at)
                     at_ms = dt.to_unix_ms
                     delete_after = true
                     Cron::CronSchedule.new(kind: Cron::ScheduleKind::At, at_ms: at_ms)
                   else
                     return ToolResult.error("either every_seconds, cron_expr, or at is required")
                   end

        job = @cron.add_job(
          name: message.size > 30 ? message[0, 30] : message,
          schedule: schedule,
          message: message,
          deliver: true,
          channel: @channel,
          to: @chat_id,
          delete_after_run: delete_after
        )

        ToolResult.success("Created job '#{job.name}' (id: #{job.id})")
      end

      private def list_jobs : ToolResult
        jobs = @cron.list_jobs
        return ToolResult.success("No scheduled jobs.") if jobs.empty?

        lines = jobs.map { |j| "- #{j.name} (id: #{j.id}, #{j.schedule.kind})" }
        ToolResult.success("Scheduled jobs:\n#{lines.join("\n")}")
      end

      private def remove_job(params : Hash(String, JSON::Any)) : ToolResult
        job_id = params["job_id"]?.try(&.as_s)
        return ToolResult.error("job_id is required for remove") unless job_id

        if @cron.remove_job(job_id)
          ToolResult.success("Removed job #{job_id}")
        else
          ToolResult.error("Job #{job_id} not found")
        end
      end
    end
  end
end
