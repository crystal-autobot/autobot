require "json"
require "uuid"
require "./types"

module Autobot
  module Cron
    # Service for managing and executing scheduled jobs.
    #
    # Jobs are persisted as JSON and executed via a fiber-based timer loop.
    class Service
      alias JobCallback = CronJob -> String?

      @store_path : Path
      @on_job : JobCallback?
      @store : CronStore?
      @running : Bool = false

      def initialize(@store_path : Path, @on_job : JobCallback? = nil)
      end

      # Start the cron service timer loop.
      def start : Nil
        @running = true
        load_store
        recompute_next_runs
        save_store
        arm_timer
        Log.info { "Cron service started with #{store.jobs.size} jobs" }
      end

      # Stop the cron service.
      def stop : Nil
        @running = false
      end

      # List all jobs (optionally including disabled ones).
      def list_jobs(include_disabled : Bool = false) : Array(CronJob)
        jobs = if include_disabled
                 store.jobs
               else
                 store.jobs.select(&.enabled?)
               end
        jobs.sort_by { |j| j.state.next_run_at_ms || Int64::MAX }
      end

      # Add a new scheduled job.
      def add_job(
        name : String,
        schedule : CronSchedule,
        message : String,
        deliver : Bool = false,
        channel : String? = nil,
        to : String? = nil,
        delete_after_run : Bool = false,
      ) : CronJob
        now = now_ms

        job = CronJob.new(
          id: UUID.random.to_s[0, 8],
          name: name,
          enabled: true,
          schedule: schedule,
          payload: CronPayload.new(
            kind: PayloadKind::AgentTurn,
            message: message,
            deliver: deliver,
            channel: channel,
            to: to
          ),
          state: CronJobState.new(next_run_at_ms: compute_next_run(schedule, now)),
          created_at_ms: now,
          updated_at_ms: now,
          delete_after_run: delete_after_run
        )

        store.jobs << job
        save_store
        arm_timer
        Log.info { "Cron: added job '#{name}' (#{job.id})" }
        job
      end

      # Remove a job by ID.
      def remove_job(job_id : String) : Bool
        before = store.jobs.size
        store.jobs.reject! { |j| j.id == job_id }
        removed = store.jobs.size < before

        if removed
          save_store
          arm_timer
          Log.info { "Cron: removed job #{job_id}" }
        end

        removed
      end

      # Enable or disable a job.
      def enable_job(job_id : String, enabled : Bool = true) : CronJob?
        store.jobs.each do |job|
          if job.id == job_id
            job.enabled = enabled
            job.updated_at_ms = now_ms
            if enabled
              job.state = CronJobState.new(
                next_run_at_ms: compute_next_run(job.schedule, now_ms),
                last_run_at_ms: job.state.last_run_at_ms,
                last_status: job.state.last_status,
                last_error: job.state.last_error
              )
            else
              job.state = CronJobState.new(
                next_run_at_ms: nil,
                last_run_at_ms: job.state.last_run_at_ms,
                last_status: job.state.last_status,
                last_error: job.state.last_error
              )
            end
            save_store
            arm_timer
            return job
          end
        end
        nil
      end

      # Manually run a job.
      def run_job(job_id : String, force : Bool = false) : Bool
        store.jobs.each do |job|
          if job.id == job_id
            return false if !force && !job.enabled?
            execute_job(job)
            save_store
            arm_timer
            return true
          end
        end
        false
      end

      # Get service status.
      def status : Hash(String, JSON::Any)
        {
          "enabled"         => JSON::Any.new(@running),
          "jobs"            => JSON::Any.new(store.jobs.size.to_i64),
          "next_wake_at_ms" => get_next_wake_ms.try { |wake_ms| JSON::Any.new(wake_ms) } || JSON::Any.new(nil),
        }
      end

      private def store : CronStore
        @store || load_store
      end

      private def load_store : CronStore
        if s = @store
          return s
        end

        if File.exists?(@store_path)
          begin
            @store = CronStore.from_json(File.read(@store_path))
          rescue ex
            Log.warn { "Failed to load cron store: #{ex.message}" }
            @store = CronStore.new
          end
        else
          @store = CronStore.new
        end

        if s = @store
          s
        else
          raise "Failed to initialize cron store"
        end
      end

      private def save_store : Nil
        return unless s = @store

        dir = @store_path.parent
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(@store_path, s.to_json)
      end

      private def now_ms : Int64
        Time.utc.to_unix_ms
      end

      private def compute_next_run(schedule : CronSchedule, current_ms : Int64) : Int64?
        case schedule.kind
        when .at?
          at = schedule.at_ms
          (at && at > current_ms) ? at : nil
        when .every?
          every = schedule.every_ms
          (every && every > 0) ? current_ms + every : nil
        when .cron?
          parse_cron_next(schedule.expr, schedule.tz)
        else
          nil
        end
      end

      # Simple cron expression parser for common patterns.
      # Supports: "MIN HOUR * * *" format. For full cron, a library would be needed.
      private def parse_cron_next(expr : String?, tz : String? = nil) : Int64?
        return nil unless expr

        parts = expr.split(/\s+/)
        return nil unless parts.size == 5

        now = Time.utc
        minute = parts[0] == "*" ? now.minute : parts[0].to_i
        hour = parts[1] == "*" ? now.hour : parts[1].to_i

        # Calculate next occurrence
        target = Time.utc(now.year, now.month, now.day, hour, minute, 0)
        target = target + 1.day if target <= now

        target.to_unix_ms
      end

      private def recompute_next_runs : Nil
        return unless s = @store
        now = now_ms
        s.jobs.each do |job|
          if job.enabled?
            job.state = CronJobState.new(
              next_run_at_ms: compute_next_run(job.schedule, now),
              last_run_at_ms: job.state.last_run_at_ms,
              last_status: job.state.last_status,
              last_error: job.state.last_error
            )
          end
        end
      end

      private def get_next_wake_ms : Int64?
        return nil unless s = @store
        times = s.jobs.compact_map { |job| job.state.next_run_at_ms if job.enabled? }
        times.empty? ? nil : times.min
      end

      private def arm_timer : Nil
        next_wake = get_next_wake_ms
        return unless next_wake && @running

        delay_ms = {0_i64, next_wake - now_ms}.max

        spawn do
          sleep delay_ms.milliseconds
          on_timer if @running
        end
      end

      private def on_timer : Nil
        return unless s = @store

        now = now_ms
        due_jobs = s.jobs.select { |job| job.enabled? && job.state.next_run_at_ms.try { |run_ms| now >= run_ms } }

        due_jobs.each do |job|
          execute_job(job)
        end

        save_store
        arm_timer
      end

      private def execute_job(job : CronJob) : Nil
        start_ms = now_ms
        Log.info { "Cron: executing job '#{job.name}' (#{job.id})" }

        begin
          if callback = @on_job
            callback.call(job)
          end

          job.state = CronJobState.new(
            next_run_at_ms: job.state.next_run_at_ms,
            last_run_at_ms: start_ms,
            last_status: JobStatus::Ok,
            last_error: nil
          )
          Log.info { "Cron: job '#{job.name}' completed" }
        rescue ex
          job.state = CronJobState.new(
            next_run_at_ms: job.state.next_run_at_ms,
            last_run_at_ms: start_ms,
            last_status: JobStatus::Error,
            last_error: ex.message
          )
          Log.error { "Cron: job '#{job.name}' failed: #{ex.message}" }
        end

        job.updated_at_ms = now_ms

        # Handle one-shot jobs
        if job.schedule.kind.at?
          if job.delete_after_run?
            store.jobs.reject! { |j| j.id == job.id }
          else
            job.enabled = false
            job.state = CronJobState.new(
              next_run_at_ms: nil,
              last_run_at_ms: job.state.last_run_at_ms,
              last_status: job.state.last_status,
              last_error: job.state.last_error
            )
          end
        else
          # Compute next run
          job.state = CronJobState.new(
            next_run_at_ms: compute_next_run(job.schedule, now_ms),
            last_run_at_ms: job.state.last_run_at_ms,
            last_status: job.state.last_status,
            last_error: job.state.last_error
          )
        end
      end
    end
  end
end
