require "json"

module Autobot
  module Cron
    enum ScheduleKind
      At    # One-time at a specific timestamp
      Every # Recurring interval
      Cron  # Cron expression
    end

    enum PayloadKind
      SystemEvent
      AgentTurn
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
      property tz : String? = nil      # Timezone for cron expressions

      def initialize(@kind : ScheduleKind, @at_ms = nil, @every_ms = nil, @expr = nil, @tz = nil)
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

      def initialize(@kind = PayloadKind::AgentTurn, @message = "", @deliver = false, @channel = nil, @to = nil)
      end
    end

    # Runtime state of a job.
    struct CronJobState
      include JSON::Serializable

      property next_run_at_ms : Int64? = nil
      property last_run_at_ms : Int64? = nil
      property last_status : JobStatus? = nil
      property last_error : String? = nil

      def initialize(@next_run_at_ms = nil, @last_run_at_ms = nil, @last_status = nil, @last_error = nil)
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
