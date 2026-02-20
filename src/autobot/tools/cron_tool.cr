require "./base"
require "../cron/service"
require "../cron/types"
require "./result"

module Autobot
  module Tools
    # Tool to schedule reminders and recurring tasks via the cron service.
    class CronTool < Tool
      JOB_NAME_MAX_LENGTH = 30

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
        "Schedule tasks: one-time (at), recurring (every_seconds/cron_expr). " \
        "Each firing triggers a background agent turn — the `message` is the turn's prompt. " \
        "Actions: add, list, remove. " \
        "To remove a job, always use `list` first to get the job ID. " \
        "Always confirm with the user before add or remove."
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
              description: "Single-execution instruction — what to do on THIS firing, not the schedule. " \
                           "Write as a direct action with specific tool names. " \
                           "Include all user-provided specifics verbatim: URLs, names, values, thresholds."
            ),
            "every_seconds" => PropertySchema.new(
              type: "integer",
              description: "Interval in seconds (for recurring tasks). Minimum: 1. " \
                           "Prefer this for sub-minute intervals."
            ),
            "cron_expr" => PropertySchema.new(
              type: "string",
              description: "Standard 5-field cron: MIN(0-59) HOUR(0-23) DOM(1-31) MON(1-12) DOW(0-6). " \
                           "Supports: * (any), ranges (9-17), steps (*/5), lists (1,15,30). " \
                           "All values must be integers. Minimum granularity: 1 minute. " \
                           "Examples: '*/5 * * * *' (every 5 min), '0 9 * * 1-5' (weekdays 9am). " \
                           "For sub-minute intervals use every_seconds instead."
            ),
            "at" => PropertySchema.new(
              type: "string",
              description: "ISO datetime for one-time execution (e.g. '2026-02-12T10:30:00')"
            ),
            "job_id" => PropertySchema.new(
              type: "string",
              description: "Job ID (for remove). Use `list` action first to get the ID."
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

        owner_key = "#{@channel}:#{@chat_id}"

        job = @cron.add_job(
          name: message.size > JOB_NAME_MAX_LENGTH ? message[0, JOB_NAME_MAX_LENGTH] : message,
          schedule: schedule,
          message: message,
          deliver: true,
          channel: @channel,
          to: @chat_id,
          delete_after_run: delete_after,
          owner: owner_key
        )

        ToolResult.success("Created job '#{job.name}' (id: #{job.id})")
      end

      private def list_jobs : ToolResult
        owner_key = owner_context
        jobs = @cron.list_jobs(owner: owner_key)
        return ToolResult.success("No scheduled jobs.") if jobs.empty?

        lines = jobs.map { |j| "- #{j.name} (id: #{j.id}, #{j.schedule.kind})" }
        ToolResult.success("Scheduled jobs:\n#{lines.join("\n")}")
      end

      private def remove_job(params : Hash(String, JSON::Any)) : ToolResult
        job_id = params["job_id"]?.try(&.as_s)
        return ToolResult.error("job_id is required for remove") unless job_id

        owner_key = owner_context

        if @cron.remove_job(job_id, owner: owner_key)
          ToolResult.success("Removed job #{job_id}")
        else
          ToolResult.error("Job #{job_id} not found or access denied")
        end
      end

      private def owner_context : String?
        return nil if @channel.empty? || @chat_id.empty?
        "#{@channel}:#{@chat_id}"
      end
    end
  end
end
