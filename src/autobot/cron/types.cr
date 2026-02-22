require "cron_parser"
require "json"

module Autobot
  module Cron
    # Build a canonical owner key from channel and chat_id.
    # Used for job ownership across CronTool and channel commands.
    def self.owner_key(channel : String, chat_id : String) : String
      "#{channel}:#{chat_id}"
    end

    enum ScheduleKind
      At    # One-time at a specific timestamp
      Every # Recurring interval
      Cron  # Cron expression
    end

    enum PayloadKind
      SystemEvent
      AgentTurn
      Exec
    end

    enum JobStatus
      Ok
      Error
      Skipped
    end

    # Schedule definition for a cron job.
    struct CronSchedule
      include JSON::Serializable

      property kind : ScheduleKind
      property at_ms : Int64? = nil    # For "at": timestamp in ms
      property every_ms : Int64? = nil # For "every": interval in ms
      property expr : String? = nil    # For "cron": cron expression

      def initialize(@kind : ScheduleKind, @at_ms = nil, @every_ms = nil, @expr = nil)
      end
    end

    # Builds a CronSchedule from user-provided parameters.
    # Shared by both CronTool and CLI to avoid schedule construction duplication.
    module ScheduleBuilder
      MIN_INTERVAL_SECONDS = 1

      # Build a schedule from raw parameters.
      # Returns {schedule, delete_after_run} or nil if no schedule params given.
      # Raises on validation errors (invalid interval, bad time format).
      def self.build(every_seconds : Int64?, cron_expr : String?, at : String?) : {CronSchedule, Bool}?
        if every_seconds
          if every_seconds < MIN_INTERVAL_SECONDS
            raise ArgumentError.new("every_seconds must be at least #{MIN_INTERVAL_SECONDS}")
          end
          {CronSchedule.new(kind: ScheduleKind::Every, every_ms: every_seconds * 1000), false}
        elsif cron_expr
          validate_cron_expr(cron_expr)
          {CronSchedule.new(kind: ScheduleKind::Cron, expr: cron_expr), false}
        elsif at
          at_ms = Time.parse_iso8601(at).to_unix_ms
          if at_ms <= Time.utc.to_unix_ms
            raise ArgumentError.new("at must be in the future")
          end
          {CronSchedule.new(kind: ScheduleKind::At, at_ms: at_ms), true}
        else
          nil
        end
      end

      private def self.validate_cron_expr(expr : String) : Nil
        CronParser.new(expr).next(Time.utc)
      rescue ex : ArgumentError
        raise ArgumentError.new("invalid cron expression '#{expr}': #{ex.message}")
      end
    end

    # What to do when the job runs.
    struct CronPayload
      include JSON::Serializable

      property kind : PayloadKind = PayloadKind::AgentTurn
      property message : String = ""
      property? deliver : Bool = false
      property channel : String? = nil
      property to : String? = nil
      property command : String? = nil

      def initialize(@kind = PayloadKind::AgentTurn, @message = "", @deliver = false, @channel = nil, @to = nil, @command = nil)
      end
    end

    # Runtime state of a job.
    struct CronJobState
      include JSON::Serializable

      property last_run_at_ms : Int64? = nil
      property last_status : JobStatus? = nil
      property last_error : String? = nil
      property last_output : String? = nil

      def initialize(@last_run_at_ms = nil, @last_status = nil, @last_error = nil, @last_output = nil)
      end

      # Create a copy with selectively overridden fields.
      def copy(
        last_run_at_ms : Int64? | Nil = @last_run_at_ms,
        last_status : JobStatus? | Nil = @last_status,
        last_error : String? | Nil = @last_error,
        last_output : String? | Nil = @last_output,
      ) : CronJobState
        CronJobState.new(
          last_run_at_ms: last_run_at_ms,
          last_status: last_status,
          last_error: last_error,
          last_output: last_output,
        )
      end
    end

    # A scheduled job.
    class CronJob
      include JSON::Serializable

      property id : String
      property name : String
      property? enabled : Bool = true
      property schedule : CronSchedule
      property payload : CronPayload
      property state : CronJobState
      property created_at_ms : Int64 = 0
      property updated_at_ms : Int64 = 0
      property? delete_after_run : Bool = false
      property owner : String? = nil # Format: "channel:chat_id" for authorization

      def initialize(
        @id : String,
        @name : String,
        @enabled = true,
        @schedule = CronSchedule.new(kind: ScheduleKind::Every),
        @payload = CronPayload.new,
        @state = CronJobState.new,
        @created_at_ms = 0_i64,
        @updated_at_ms = 0_i64,
        @delete_after_run = false,
        @owner : String? = nil,
      )
      end
    end

    # Persistent store for cron jobs.
    struct CronStore
      include JSON::Serializable

      property version : Int32 = 1
      property jobs : Array(CronJob) = [] of CronJob

      def initialize(@version = 1, @jobs = [] of CronJob)
      end
    end
  end
end
