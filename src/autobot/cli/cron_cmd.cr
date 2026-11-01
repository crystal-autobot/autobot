require "../cron/formatter"

module Autobot
  module CLI
    module CronCmd
      TABLE_FORMAT     = "%-10s %-8s %-20s %-20s %-10s %-20s"
      TABLE_WIDTH      = 92
      COLUMN_MAX_WIDTH = 20
      NIL_PLACEHOLDER  = "-"

      def self.list(config_path : String?, include_all : Bool) : Nil
        service = readonly_cron_service(config_path)
        jobs = service.list_jobs(include_disabled: include_all)

        if jobs.empty?
          puts "No scheduled jobs."
          return
        end

        puts TABLE_FORMAT % ["ID", "Type", "Name", "Schedule", "Status", "Next Run"]
        puts "-" * TABLE_WIDTH

        jobs.each do |job|
          sched = Cron::Formatter.format_schedule(job.schedule)
          next_run = format_time_ms(service.compute_next_run_for(job))
          status = job.enabled? ? "enabled" : "disabled"
          type = Cron::Formatter.format_type_tag(job)

          puts TABLE_FORMAT % [job.id, type, job.name[0, COLUMN_MAX_WIDTH], sched[0, COLUMN_MAX_WIDTH], status, next_run]
        end
      end

      def self.show(config_path : String?, job_id : String) : Nil
        service = readonly_cron_service(config_path)
        job = service.get_job(job_id)
        unless job
          STDERR.puts "Job #{job_id} not found"
          exit 1
        end

        status = job.enabled? ? "enabled" : "disabled"

        detail_label = job.payload.kind.exec? ? "Command" : "Message"
        detail = Cron::Formatter.format_job_detail(job)

        puts "ID:       #{job.id}"
        puts "Name:     #{job.name}"
        puts "Type:     #{Cron::Formatter.format_type_tag(job)}"
        puts "Status:   #{status}"
        puts "Schedule: #{Cron::Formatter.format_schedule(job.schedule)}"
        puts "Next Run: #{format_time_ms(service.compute_next_run_for(job))}"
        puts "Last Run: #{format_time_ms(job.state.last_run_at_ms)}"
        puts "#{detail_label}: #{detail}"
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

        job = cron_service(config_path).add_job(
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
        if cron_service(config_path).remove_job(job_id)
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

        if job = cron_service(config_path).update_job(job_id, schedule: schedule, message: message)
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
        if job = cron_service(config_path).enable_job(job_id, enabled: enabled)
          status = enabled ? "enabled" : "disabled"
          puts "✓ Job '#{job.name}' #{status}"
        else
          STDERR.puts "Job #{job_id} not found"
          exit 1
        end
      end

      def self.clear(config_path : String?) : Nil
        count = cron_service(config_path).clear_all
        puts "Removed #{count} job(s)."
      end

      def self.run_job(config_path : String?, job_id : String, force : Bool) : Nil
        exit 1 unless execute_run_job(config_path, job_id, force: force)
      end

      def self.execute_run_job(
        config_path : String?,
        job_id : String,
        force : Bool = false,
        io : IO = STDOUT,
        err_io : IO = STDERR,
      ) : Bool
        service = runnable_cron_service(config_path, io: io)

        unless service.run_job(job_id, force: force)
          err_io.puts "Failed to run job #{job_id}"
          return false
        end

        if (job = service.get_job(job_id)) && job.state.last_status == Cron::JobStatus::Error
          err_io.puts "Job #{job_id} failed: #{job.state.last_error || "unknown error"}"
          return false
        end

        io.puts "✓ Job executed"
        true
      end

      def self.cron_service(config_path : String?) : Cron::Service
        Cron::Service.new(Config::Loader.load(config_path, validate: false).cron_store_path)
      end

      def self.readonly_cron_service(config_path : String?) : Cron::Service
        Cron::Service.new(Config::Loader.load_or_default(config_path).cron_store_path)
      end

      def self.runnable_cron_service(config_path : String?, io : IO = STDOUT) : Cron::Service
        config = Config::Loader.load(config_path, validate: false)
        runner = JobRunner.new(config, io)
        service = Cron::Service.from_config(
          config,
          sandbox: runner.sandbox,
          on_job: ->runner.run_agent_turn(Cron::CronJob),
          on_exec: ->runner.print_exec_output(Cron::CronJob, String),
        )
        runner.service = service
        service
      end

      private class JobRunner
        property service : Cron::Service?
        getter sandbox : Tools::Sandbox::Type
        @channels : Channels::Manager?

        def initialize(@config : Config::Config, @io : IO)
          @sandbox = SetupHelper.configure_sandbox(@config)
        end

        def run_agent_turn(job : Cron::CronJob) : String?
          provider = SetupHelper.create_provider(@config)
          bus = Bus::MessageBus.new
          session_manager = Session::Manager.new(@config.workspace_path)
          tool_registry, mcp_clients, rate_limiter = SetupHelper.setup_tools(@config, background_mcp: false, sandbox: @sandbox)
          plugin_registry = SetupHelper.load_plugins(@config, tool_registry)
          agent_loop = SetupHelper.create_agent_loop(@config, bus, provider, tool_registry, session_manager, @service, rate_limiter)

          output = agent_loop.run_cron_job(job)
          @io.puts output if output.presence
          bus.drain_outbound { |event| channels.dispatch(event) } if job.payload.delivery_target
          output
        ensure
          mcp_clients.try { |clients| Mcp.stop_all(clients) }
          plugin_registry.try(&.stop_all)
        end

        def print_exec_output(job : Cron::CronJob, output : String) : Nil
          @io.puts output
          return unless target = job.payload.delivery_target

          channel, chat_id = target
          channels.dispatch(Bus::OutboundMessage.new(
            channel: channel,
            chat_id: chat_id,
            content: Cron::Formatter.format_exec_output(job, output),
          ))
        end

        private def channels : Channels::Manager
          @channels ||= Channels::Manager.new(@config, Bus::MessageBus.new)
        end
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
