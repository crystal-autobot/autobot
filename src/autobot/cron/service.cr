require "json"
require "uuid"
require "cron_parser"
require "./types"

module Autobot
  module Cron
    # Service for managing and executing scheduled jobs.
    #
    # Jobs are persisted as JSON and executed via a fiber-based timer loop.
    class Service
      alias JobCallback = CronJob -> String?

      RELOAD_CHECK_INTERVAL = 60.seconds

      @store_path : Path
      @on_job : JobCallback?
      @store : CronStore?
      @running : Bool = false
      @timer_generation : Int64 = 0
      @store_mtime : Time? = nil

      def initialize(@store_path : Path, @on_job : JobCallback? = nil)
      end

      # Start the cron service timer loop.
      def start : Nil
        @running = true
        @store = nil
        load_store
        arm_timer
        start_reload_checker
        Log.info { "Cron service started with #{store.jobs.size} jobs" }
      end

      # Stop the cron service.
      def stop : Nil
        @running = false
      end

      # List all jobs (optionally including disabled ones).
      # If owner is provided, only returns jobs owned by that owner.
      def list_jobs(include_disabled : Bool = false, owner : String? = nil) : Array(CronJob)
        jobs = if include_disabled
                 store.jobs
               else
                 store.jobs.select(&.enabled?)
               end

        jobs = jobs.select { |j| j.owner == owner } if owner

        jobs.sort_by { |j| compute_next_run_for(j) || Int64::MAX }
      end

      # Find a single job by ID, optionally enforcing owner access.
      def get_job(job_id : String, owner : String? = nil) : CronJob?
        job = store.jobs.find { |j| j.id == job_id }
        return nil unless job
        return nil if owner && job.owner != owner
        job
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
        owner : String? = nil,
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
          state: CronJobState.new,
          created_at_ms: now,
          updated_at_ms: now,
          delete_after_run: delete_after_run,
          owner: owner
        )

        store.jobs << job
        save_store
        arm_timer
        Log.info { "Cron: added job '#{name}' (#{job.id})" }
        job
      end

      # Remove all jobs and return the count of removed jobs.
      def clear_all : Int32
        count = store.jobs.size
        store.jobs.clear
        save_store
        arm_timer
        Log.info { "Cron: cleared #{count} job(s)" }
        count
      end

      # Remove a job by ID.
      # If owner is provided, only removes job if it matches the owner.
      def remove_job(job_id : String, owner : String? = nil) : Bool
        job_to_remove = store.jobs.find { |j| j.id == job_id }
        return false unless job_to_remove

        # Check ownership if provided
        if owner && job_to_remove.owner != owner
          return false
        end

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

      # Update a job's schedule and/or message in place.
      # Returns the updated job, or nil if not found / access denied.
      def update_job(
        job_id : String,
        owner : String? = nil,
        schedule : CronSchedule? = nil,
        message : String? = nil,
      ) : CronJob?
        store.jobs.each do |job|
          if job.id == job_id
            return nil if owner && job.owner != owner

            job.schedule = schedule if schedule
            if msg = message
              job.payload = CronPayload.new(
                kind: job.payload.kind,
                message: msg,
                deliver: job.payload.deliver?,
                channel: job.payload.channel,
                to: job.payload.to,
              )
            end
            job.updated_at_ms = now_ms
            save_store
            arm_timer
            return job
          end
        end
        nil
      end

      # Enable or disable a job.
      # If owner is provided, only modifies job if it matches the owner.
      def enable_job(job_id : String, enabled : Bool = true, owner : String? = nil) : CronJob?
        store.jobs.each do |job|
          if job.id == job_id
            return nil if owner && job.owner != owner
            job.enabled = enabled
            job.updated_at_ms = now_ms
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
            @store_mtime = File.info(@store_path).modification_time
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

      # Reload store from disk if the file was modified externally (e.g. by CLI).
      private def reload_if_changed : Bool
        return false unless File.exists?(@store_path)

        current_mtime = File.info(@store_path).modification_time
        return false if @store_mtime && current_mtime == @store_mtime

        begin
          @store = CronStore.from_json(File.read(@store_path))
          @store_mtime = current_mtime
          Log.info { "Cron: store reloaded from disk (#{store.jobs.size} jobs)" }
          true
        rescue ex
          Log.warn { "Failed to reload cron store: #{ex.message}" }
          false
        end
      end

      private def save_store : Nil
        return unless s = @store

        dir = @store_path.parent
        unless Dir.exists?(dir)
          Dir.mkdir_p(dir)
          File.chmod(dir, 0o700)
        end

        File.write(@store_path, s.to_json)
        File.chmod(@store_path, 0o600)
        @store_mtime = File.info(@store_path).modification_time
      end

      private def now_ms : Int64
        Time.utc.to_unix_ms
      end

      # Compute next run for a job, using last_run for interval jobs or expression for cron jobs.
      def compute_next_run_for(job : CronJob) : Int64?
        return nil unless job.enabled?
        compute_next_run(job.schedule, job.state.last_run_at_ms || job.created_at_ms)
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
          parse_cron_next(schedule.expr, current_ms)
        else
          nil
        end
      end

      # Parse a cron expression and return the next run time in ms.
      # Delegates to the cron_parser shard which supports:
      # *, fixed values, ranges (1-5), steps (*/5), lists (1,15,30),
      # combos (1-30/10), named months/days, and @hourly/@daily etc.
      private def parse_cron_next(expr : String?, after_ms : Int64? = nil) : Int64?
        return nil unless expr
        base_time = after_ms ? Time.unix_ms(after_ms) : Time.utc
        CronParser.new(expr).next(base_time).to_unix_ms
      rescue ArgumentError
        nil
      end

      private def get_next_wake_ms : Int64?
        return nil unless s = @store
        times = s.jobs.compact_map { |job| compute_next_run_for(job) }
        times.empty? ? nil : times.min
      end

      private def arm_timer : Nil
        next_wake = get_next_wake_ms
        return unless next_wake && @running

        @timer_generation += 1
        generation = @timer_generation
        delay_ms = {0_i64, next_wake - now_ms}.max

        spawn do
          sleep delay_ms.milliseconds
          on_timer if @running && generation == @timer_generation
        rescue ex
          Log.error { "Cron timer error: #{ex.message}" }
          arm_timer if @running
        end
      end

      private def on_timer : Nil
        reload_if_changed
        return unless s = @store

        now = now_ms
        due_jobs = s.jobs.select do |job|
          next_run = compute_next_run_for(job)
          next_run && now >= next_run
        end

        due_jobs.each do |job|
          execute_job(job)
          save_store
        end

        arm_timer
      end

      # Periodically check for external store changes (e.g. CLI adds a job).
      private def start_reload_checker : Nil
        spawn do
          while @running
            sleep RELOAD_CHECK_INTERVAL
            next unless @running
            if reload_if_changed
              arm_timer
            end
          end
        rescue ex
          Log.error { "Cron reload checker error: #{ex.message}" }
        end
      end

      private def execute_job(job : CronJob) : Nil
        start_ms = now_ms
        Log.debug { "Cron: executing job '#{job.name}' (#{job.id})" }

        run_job_callback(job, start_ms)
        job.updated_at_ms = now_ms
        schedule_next_run(job)
      end

      private def run_job_callback(job : CronJob, start_ms : Int64) : Nil
        if callback = @on_job
          callback.call(job)
        end
        job.state = job.state.copy(last_run_at_ms: start_ms, last_status: JobStatus::Ok, last_error: nil)
        Log.debug { "Cron: job '#{job.name}' completed" }
      rescue ex
        job.state = job.state.copy(last_run_at_ms: start_ms, last_status: JobStatus::Error, last_error: ex.message)
        Log.error { "Cron: job '#{job.name}' failed: #{ex.message}" }
      end

      private def schedule_next_run(job : CronJob) : Nil
        return unless job.schedule.kind.at?

        if job.delete_after_run?
          store.jobs.reject! { |j| j.id == job.id }
        else
          job.enabled = false
        end
      end
    end
  end
end
