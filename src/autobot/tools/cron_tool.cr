require "./base"
require "../cron/formatter"
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
        "Actions: add, list, remove, update, show. " \
        "To remove or update a job, always use `list` first to get the job ID. " \
        "Always confirm with the user before add, remove, or update."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "action" => PropertySchema.new(
              type: "string",
              enum_values: ["add", "list", "remove", "update", "show"],
              description: "Action to perform"
            ),
            "name" => PropertySchema.new(
              type: "string",
              description: "Short human-readable label for the job (max 30 chars). " \
                           "Shown in /cron and list output. Example: 'GitHub stars check'"
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
              description: "Job ID (for show/remove/update). Use `list` action first to get the ID."
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
        when "show"
          show_job(params)
        when "remove"
          remove_job(params)
        when "update"
          update_job(params)
        else
          ToolResult.error("Unknown action: #{action}")
        end
      end

      private def add_job(params : Hash(String, JSON::Any)) : ToolResult
        message = params["message"]?.try(&.as_s) || ""
        return ToolResult.error("message is required for add") if message.empty?
        return ToolResult.error("no session context (channel/chat_id)") if @channel.empty? || @chat_id.empty?

        result = build_schedule(params)
        return ToolResult.error("either every_seconds, cron_expr, or at is required") unless result

        schedule, delete_after = result
        job_name = derive_job_name(params, message)

        job = @cron.add_job(
          name: job_name,
          schedule: schedule,
          message: message,
          deliver: true,
          channel: @channel,
          to: @chat_id,
          delete_after_run: delete_after,
          owner: owner_context
        )

        ToolResult.success("Created job '#{job.name}' (id: #{job.id})")
      rescue ex : ArgumentError
        ToolResult.error(ex.message || "Invalid schedule parameters")
      end

      private def update_job(params : Hash(String, JSON::Any)) : ToolResult
        job_id = params["job_id"]?.try(&.as_s)
        return ToolResult.error("job_id is required for update") unless job_id
        return ToolResult.error("no session context (channel/chat_id)") unless owner_context

        message = params["message"]?.try(&.as_s)
        result = build_schedule(params)
        schedule = result.try(&.first)

        return ToolResult.error("provide message, every_seconds, cron_expr, or at to update") unless message || schedule

        if job = @cron.update_job(job_id, owner: owner_context, schedule: schedule, message: message)
          ToolResult.success("Updated job '#{job.name}' (id: #{job.id})")
        else
          ToolResult.error("Job #{job_id} not found or access denied")
        end
      rescue ex : ArgumentError
        ToolResult.error(ex.message || "Invalid schedule parameters")
      end

      private def list_jobs : ToolResult
        return ToolResult.error("no session context (channel/chat_id)") unless owner_context
        jobs = @cron.list_jobs(owner: owner_context)
        return ToolResult.success("No scheduled jobs.") if jobs.empty?

        lines = jobs.map { |j| format_job_line(j) }
        ToolResult.success("Scheduled jobs (#{jobs.size}):\n#{lines.join("\n")}")
      end

      private def show_job(params : Hash(String, JSON::Any)) : ToolResult
        job_id = params["job_id"]?.try(&.as_s)
        return ToolResult.error("job_id is required for show") unless job_id
        return ToolResult.error("no session context (channel/chat_id)") unless owner_context

        jobs = @cron.list_jobs(include_disabled: true, owner: owner_context)
        job = jobs.find { |j| j.id == job_id }
        return ToolResult.error("Job #{job_id} not found or access denied") unless job

        format_job_details(job)
      end

      private def remove_job(params : Hash(String, JSON::Any)) : ToolResult
        job_id = params["job_id"]?.try(&.as_s)
        return ToolResult.error("job_id is required for remove") unless job_id
        return ToolResult.error("no session context (channel/chat_id)") unless owner_context

        if @cron.remove_job(job_id, owner: owner_context)
          ToolResult.success("Removed job #{job_id}")
        else
          ToolResult.error("Job #{job_id} not found or access denied")
        end
      end

      private def owner_context : String?
        return nil if @channel.empty? || @chat_id.empty?
        "#{@channel}:#{@chat_id}"
      end

      private def derive_job_name(params : Hash(String, JSON::Any), message : String) : String
        name = params["name"]?.try(&.as_s)
        if name && !name.empty?
          name.size > JOB_NAME_MAX_LENGTH ? name[0, JOB_NAME_MAX_LENGTH] : name
        else
          message.size > JOB_NAME_MAX_LENGTH ? message[0, JOB_NAME_MAX_LENGTH] : message
        end
      end

      private def format_job_line(job : Cron::CronJob) : String
        next_run = @cron.compute_next_run_for(job)
        last_run = Cron::Formatter.format_relative_time(job.state.last_run_at_ms)
        last_status = job.state.last_status.try(&.to_s.downcase) || "n/a"
        next_run_str = next_run ? Cron::Formatter.format_relative_time(next_run) : "n/a"

        "- #{job.id} | #{job.name}\n" \
        "  Schedule: #{Cron::Formatter.format_schedule(job.schedule)} | Last: #{last_run} (#{last_status}) | Next: #{next_run_str}"
      end

      private def format_job_details(job : Cron::CronJob) : ToolResult
        next_run = @cron.compute_next_run_for(job)
        status = job.enabled? ? "enabled" : "disabled"
        last_run = Cron::Formatter.format_relative_time(job.state.last_run_at_ms)
        last_status = job.state.last_status.try(&.to_s.downcase) || "n/a"

        lines = [
          "ID: #{job.id}",
          "Name: #{job.name}",
          "Status: #{status}",
          "Schedule: #{Cron::Formatter.format_schedule(job.schedule)}",
          "Next run: #{next_run ? Cron::Formatter.format_relative_time(next_run) : "n/a"}",
          "Last run: #{last_run} (#{last_status})",
          "Message: #{job.payload.message}",
        ]

        ToolResult.success(lines.join("\n"))
      end

      # Parse schedule params via the shared ScheduleBuilder.
      private def build_schedule(params : Hash(String, JSON::Any)) : Tuple(Cron::CronSchedule, Bool)?
        Cron::ScheduleBuilder.build(
          every_seconds: params["every_seconds"]?.try(&.as_i64),
          cron_expr: params["cron_expr"]?.try(&.as_s),
          at: params["at"]?.try(&.as_s),
        )
      end
    end
  end
end
