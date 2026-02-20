module Autobot
  module CLI
    module CronCmd
      TABLE_FORMAT = "%-10s %-20s %-20s %-10s %-20s"
      TABLE_WIDTH  = 82

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
          sched = format_schedule(job.schedule)
          next_run = format_next_run(service.compute_next_run_for(job))
          status = job.enabled? ? "enabled" : "disabled"

          puts TABLE_FORMAT % [job.id, job.name[0, 20], sched[0, 20], status, next_run]
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
        puts "Schedule: #{format_schedule(job.schedule)}"
        puts "Next Run: #{format_next_run(service.compute_next_run_for(job))}"
        puts "Message:  #{job.payload.message}"
        puts "Deliver:  #{job.payload.deliver?}"
        puts "Channel:  #{job.payload.channel || "-"}"
        puts "To:       #{job.payload.to || "-"}"
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
        schedule = if every
                     Cron::CronSchedule.new(kind: Cron::ScheduleKind::Every, every_ms: every.to_i64 * 1000)
                   elsif cron_expr
                     Cron::CronSchedule.new(kind: Cron::ScheduleKind::Cron, expr: cron_expr)
                   elsif at
                     begin
                       time = Time.parse_iso8601(at)
                       Cron::CronSchedule.new(kind: Cron::ScheduleKind::At, at_ms: time.to_unix_ms)
                     rescue ex
                       STDERR.puts "Error: Invalid time format: #{ex.message}"
                       exit 1
                     end
                   else
                     STDERR.puts "Error: Must specify --every, --cron, or --at"
                     exit 1
                   end

        job = cron_service.add_job(
          name: name,
          schedule: schedule,
          message: message,
          deliver: deliver,
          to: to,
          channel: channel
        )

        puts "✓ Added job '#{job.name}' (#{job.id})"
      end

      def self.remove(config_path : String?, job_id : String) : Nil
        if cron_service.remove_job(job_id)
          puts "✓ Removed job #{job_id}"
        else
          STDERR.puts "Job #{job_id} not found"
          exit 1
        end
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

      private def self.format_schedule(schedule : Cron::CronSchedule) : String
        case schedule.kind
        when .every?
          every = schedule.every_ms
          every ? "every #{every // 1000}s" : "every ?"
        when .cron?
          schedule.expr || ""
        when .at?
          "one-time"
        else
          "unknown"
        end
      end

      private def self.format_next_run(next_run_at_ms : Int64?) : String
        if ms = next_run_at_ms
          Time.unix_ms(ms).to_s("%Y-%m-%d %H:%M")
        else
          "-"
        end
      end
    end
  end
end
