require "../cron/formatter"

module Autobot
  module CLI
    module CronCmd
      TABLE_FORMAT     = "%-10s %-20s %-20s %-10s %-20s"
      TABLE_WIDTH      = 82
      COLUMN_MAX_WIDTH = 20
      NIL_PLACEHOLDER  = "-"

      def self.list(config_path : String?, include_all : Bool) : Nil
        service = cron_service
        jobs = service.list_jobs(include_disabled: include_all)

        if jobs.empty?
          puts "No scheduled jobs."
          return
        end

        puts TABLE_FORMAT % ["ID", "Name", "Schedule", "Status", "Next Run"]
        puts "-" * TABLE_WIDTH

        jobs.each do |job|
          sched = Cron::Formatter.format_schedule(job.schedule)
          next_run = format_time_ms(service.compute_next_run_for(job))
          status = job.enabled? ? "enabled" : "disabled"

          puts TABLE_FORMAT % [job.id, job.name[0, COLUMN_MAX_WIDTH], sched[0, COLUMN_MAX_WIDTH], status, next_run]
        end
      end

      def self.show(config_path : String?, job_id : String) : Nil
        service = cron_service
        job = service.list_jobs(include_disabled: true).find { |j| j.id == job_id }
        unless job
          STDERR.puts "Job #{job_id} not found"
          exit 1
        end

        status = job.enabled? ? "enabled" : "disabled"

        puts "ID:       #{job.id}"
        puts "Name:     #{job.name}"
        puts "Status:   #{status}"
        puts "Schedule: #{Cron::Formatter.format_schedule(job.schedule)}"
        puts "Next Run: #{format_time_ms(service.compute_next_run_for(job))}"
        puts "Last Run: #{format_time_ms(job.state.last_run_at_ms)}"
        puts "Message:  #{job.payload.message}"
        puts "Deliver:  #{job.payload.deliver?}"
        puts "Channel:  #{job.payload.channel || NIL_PLACEHOLDER}"
        puts "To:       #{job.payload.to || NIL_PLACEHOLDER}"
      end

      def self.add(
        config_path : String?,
        name : String,
        message : String,
        every : Int32?,
        cron_expr : String?,
        at : String?,
        deliver : Bool,
        to : String?,
        channel : String?,
      ) : Nil
        result = Cron::ScheduleBuilder.build(
          every_seconds: every.try(&.to_i64),
          cron_expr: cron_expr,
          at: at,
        )

        unless result
          STDERR.puts "Error: Must specify --every, --cron, or --at"
          exit 1
        end

        schedule, _ = result

        job = cron_service.add_job(
          name: name,
          schedule: schedule,
          message: message,
          deliver: deliver,
          to: to,
          channel: channel
        )

        puts "✓ Added job '#{job.name}' (#{job.id})"
      rescue ex : ArgumentError
        STDERR.puts "Error: #{ex.message}"
        exit 1
      end

      def self.remove(config_path : String?, job_id : String) : Nil
        if cron_service.remove_job(job_id)
          puts "✓ Removed job #{job_id}"
        else
          STDERR.puts "Job #{job_id} not found"
          exit 1
        end
      end

      def self.update(
        config_path : String?,
        job_id : String,
        message : String?,
        every : Int32?,
        cron_expr : String?,
        at : String?,
      ) : Nil
        result = Cron::ScheduleBuilder.build(
          every_seconds: every.try(&.to_i64),
          cron_expr: cron_expr,
          at: at,
        )
        schedule = result.try(&.first)

        unless message || schedule
          STDERR.puts "Error: Must specify --message, --every, --cron, or --at"
          exit 1
        end

        if job = cron_service.update_job(job_id, schedule: schedule, message: message)
          puts "✓ Updated job '#{job.name}' (#{job.id})"
        else
          STDERR.puts "Job #{job_id} not found"
          exit 1
        end
      rescue ex : ArgumentError
        STDERR.puts "Error: #{ex.message}"
        exit 1
      end

      def self.enable(config_path : String?, job_id : String, enabled : Bool) : Nil
        if job = cron_service.enable_job(job_id, enabled: enabled)
          status = enabled ? "enabled" : "disabled"
          puts "✓ Job '#{job.name}' #{status}"
        else
          STDERR.puts "Job #{job_id} not found"
          exit 1
        end
      end

      def self.clear(config_path : String?) : Nil
        count = cron_service.clear_all
        puts "Removed #{count} job(s)."
      end

      def self.run_job(config_path : String?, job_id : String, force : Bool) : Nil
        if cron_service.run_job(job_id, force: force)
          puts "✓ Job executed"
        else
          STDERR.puts "Failed to run job #{job_id}"
          exit 1
        end
      end

      private def self.cron_service : Cron::Service
        Cron::Service.new(Config::Loader.cron_store_path)
      end

      private def self.format_time_ms(time_ms : Int64?) : String
        if ms = time_ms
          Time.unix_ms(ms).to_s(Cron::Formatter::TIME_FORMAT)
        else
          NIL_PLACEHOLDER
        end
      end
    end
  end
end
