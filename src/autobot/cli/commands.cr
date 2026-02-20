require "option_parser"
require "log"

module Autobot
  module CLI
    Log = ::Log.for("cli")

    LOGO = <<-LOGO

    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║     █████╗ ██╗   ██╗████████╗ ██████╗ ██████╗  ██████╗ ████████╗  ║
    ║    ██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗██╔══██╗██╔═══██╗╚══██╔══╝  ║
    ║    ███████║██║   ██║   ██║   ██║   ██║██████╔╝██║   ██║   ██║     ║
    ║    ██╔══██║██║   ██║   ██║   ██║   ██║██╔══██╗██║   ██║   ██║     ║
    ║    ██║  ██║╚██████╔╝   ██║   ╚██████╔╝██████╔╝╚██████╔╝   ██║     ║
    ║    ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═════╝  ╚═════╝    ╚═╝     ║
    ║                                                                   ║
    ║              ⚡ Crystal-Powered AI Agent Framework ⚡             ║
    ║                     Fast • Secure • Efficient                     ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝
    LOGO

    EXIT_COMMANDS = Set{"exit", "quit", "/exit", "/quit", ":q"}

    DEFAULT_SESSION_ID = "cli:default"
    DEFAULT_PORT       = 18790

    module Commands
      def self.run
        options = parse_options(ARGV.dup)

        if options[:show_version]
          print_version
          return
        end

        setup_logging(options[:verbose])
        dispatch_command(options)
      end

      private def self.dispatch_command(options) : Nil
        case options[:command]
        when "help", "-h", "--help"
          print_help
        when "new"
          handle_new_command(options)
        when "doctor"
          Doctor.run(options[:config_path], options[:strict])
        when "agent"
          Agent.run(options[:config_path], options[:message], options[:session_id], options[:markdown], options[:show_logs])
        when "gateway"
          Gateway.run(options[:config_path], options[:port], options[:verbose])
        when "cron"
          handle_cron_subcommand(options)
        when "status"
          Status.run(options[:config_path])
        when "version"
          print_version
        else
          STDERR.puts "Unknown command: #{options[:command]}"
          STDERR.puts "Run 'autobot help' for usage."
          exit 1
        end
      end

      private def self.handle_new_command(options) : Nil
        name = options[:args].shift?
        unless name
          STDERR.puts "Error: Bot name required"
          STDERR.puts "Usage: autobot new <name>"
          exit 1
        end
        New.run(name)
      end

      private def self.handle_cron_subcommand(options) : Nil
        subcommand = options[:args].shift? || "list"

        case subcommand
        when "list"
          CronCmd.list(options[:config_path], options[:cron_all])
        when "add"
          handle_cron_add(options)
        when "update"
          handle_cron_update(options)
        when "clear"
          CronCmd.clear(options[:config_path])
        when "help"
          print_cron_help
        else
          handle_cron_job_command(subcommand, options)
        end
      end

      private def self.handle_cron_job_command(subcommand : String, options) : Nil
        case subcommand
        when "show"
          CronCmd.show(options[:config_path], require_job_id(options[:args]))
        when "remove"
          CronCmd.remove(options[:config_path], require_job_id(options[:args]))
        when "enable", "disable"
          CronCmd.enable(options[:config_path], require_job_id(options[:args]), subcommand == "enable")
        when "run"
          CronCmd.run_job(options[:config_path], require_job_id(options[:args]), options[:cron_force])
        else
          STDERR.puts "Unknown cron subcommand: #{subcommand}"
          STDERR.puts "Run 'autobot cron help' for usage."
          exit 1
        end
      end

      private def self.handle_cron_update(options) : Nil
        job_id = require_job_id(options[:args])
        CronCmd.update(
          options[:config_path], job_id,
          options[:message] || options[:cron_message],
          options[:cron_every], options[:cron_expr], options[:cron_at]
        )
      end

      private def self.handle_cron_add(options) : Nil
        job_name = options[:cron_name]
        msg = options[:message] || options[:cron_message]
        unless job_name && msg
          STDERR.puts "Error: --name and --message are required"
          exit 1
        end
        CronCmd.add(
          options[:config_path], job_name, msg,
          options[:cron_every], options[:cron_expr], options[:cron_at],
          options[:cron_deliver], options[:cron_to], options[:cron_channel]
        )
      end

      private def self.setup_logging(verbose : Bool) : Nil
        level = verbose ? ::Log::Severity::Debug : ::Log::Severity::Info
        Logging.setup(level)
      end

      private def self.parse_options(args : Array(String))
        command = "help"

        # Global flags
        config_path : String? = nil
        verbose = false
        show_version = false
        strict = false

        # Agent flags
        message : String? = nil
        session_id = DEFAULT_SESSION_ID
        markdown = true
        show_logs = false

        # Gateway flags
        port = DEFAULT_PORT

        # Cron flags
        cron_all = false
        cron_name : String? = nil
        cron_message : String? = nil
        cron_every : Int32? = nil
        cron_expr : String? = nil
        cron_at : String? = nil
        cron_deliver = false
        cron_to : String? = nil
        cron_channel : String? = nil
        cron_force = false

        # Determine command from first non-flag argument
        if args.size > 0 && !args[0].starts_with?("-")
          command = args.shift
        end

        parser = OptionParser.new do |option_parser|
          option_parser.banner = "Usage: autobot <command> [options]"

          option_parser.on("-c PATH", "--config PATH", "Path to config file") { |v| config_path = v }
          option_parser.on("-v", "--verbose", "Verbose output") { verbose = true }
          option_parser.on("--version", "Show version") { show_version = true }
          option_parser.on("-h", "--help", "Show help") { show_version = false }
          option_parser.on("--strict", "Strict mode (warnings as errors)") { strict = true }

          # Agent-specific
          option_parser.on("-m MSG", "--message MSG", "Message to send to agent") { |v| message = v }
          option_parser.on("-s ID", "--session ID", "Session ID") { |v| session_id = v }
          option_parser.on("--no-markdown", "Disable markdown rendering") { markdown = false }
          option_parser.on("--logs", "Show runtime logs") { show_logs = true }

          # Gateway-specific
          option_parser.on("-p PORT", "--port PORT", "Gateway port") { |v| port = v.to_i }

          # Cron-specific
          option_parser.on("-a", "--all", "Include disabled jobs in list") { cron_all = true }
          option_parser.on("-n NAME", "--name NAME", "Job name") { |v| cron_name = v }
          option_parser.on("-e SECS", "--every SECS", "Run every N seconds") { |v| cron_every = v.to_i }
          option_parser.on("--cron EXPR", "Cron expression") { |v| cron_expr = v }
          option_parser.on("--at TIME", "Run once at time (ISO)") { |v| cron_at = v }
          option_parser.on("-d", "--deliver", "Deliver response to channel") { cron_deliver = true }
          option_parser.on("--to DEST", "Recipient for delivery") { |v| cron_to = v }
          option_parser.on("--channel CH", "Channel for delivery") { |v| cron_channel = v }
          option_parser.on("-f", "--force", "Force action") { cron_force = true }

          option_parser.invalid_option { |flag| STDERR.puts "Unknown option: #{flag}" }
          option_parser.missing_option { |flag| STDERR.puts "Missing value for: #{flag}" }
        end

        parser.parse(args)

        {
          command:      command,
          args:         args,
          config_path:  config_path,
          verbose:      verbose,
          show_version: show_version,
          strict:       strict,
          message:      message,
          session_id:   session_id,
          markdown:     markdown,
          show_logs:    show_logs,
          port:         port,
          cron_all:     cron_all,
          cron_name:    cron_name,
          cron_message: cron_message,
          cron_every:   cron_every,
          cron_expr:    cron_expr,
          cron_at:      cron_at,
          cron_deliver: cron_deliver,
          cron_to:      cron_to,
          cron_channel: cron_channel,
          cron_force:   cron_force,
        }
      end

      private def self.print_cron_help : Nil
        puts "Usage: autobot cron <subcommand> [options]\n\n"
        puts "Subcommands:"
        puts "  list              List scheduled jobs (use -a to include disabled)"
        puts "  show <job_id>     Show full job details including message"
        puts "  add               Add a new job (requires -n, -m, and a schedule)"
        puts "  update <job_id>   Update a job's schedule or message"
        puts "  remove <job_id>   Remove a job"
        puts "  enable <job_id>   Enable a job"
        puts "  disable <job_id>  Disable a job"
        puts "  run <job_id>      Run a job now (use -f to force if disabled)"
        puts "  clear             Remove all jobs"
        puts "  help              Show this help"
      end

      private def self.require_job_id(args : Array(String)) : String
        job_id = args.shift?
        unless job_id
          STDERR.puts "Error: job ID required"
          exit 1
        end
        job_id
      end

      private def self.print_version : Nil
        puts "autobot v#{VERSION}"
        puts "crystal #{CRYSTAL_VERSION}"
        puts "built #{BUILD_DATE}"
      end

      private def self.print_help
        puts LOGO
        puts "autobot v#{VERSION} — AI agent framework\n\n"
        puts "Usage: autobot <command> [options]\n\n"
        puts "Commands:"
        puts "  new       Create a new bot in a directory (e.g., autobot new optimus)"
        puts "  doctor    Check configuration and security (use --strict for warnings as errors)"
        puts "  agent     Interact with the agent (single message or interactive)"
        puts "  gateway   Start the gateway server"
        puts "  cron      Manage scheduled tasks (list|show|add|update|remove|enable|disable|run|clear)"
        puts "  status    Show system status"
        puts "  version   Show version info"
        puts "  help      Show this help\n\n"
        puts "Global Options:"
        puts "  -c, --config PATH    Path to config file"
        puts "  -v, --verbose        Verbose output"
        puts "  --version            Show version\n\n"
        puts "Agent Options:"
        puts "  -m, --message MSG    Send a single message"
        puts "  -s, --session ID     Session ID (default: #{DEFAULT_SESSION_ID})"
        puts "  --no-markdown        Disable markdown rendering"
        puts "  --logs               Show runtime logs\n\n"
        puts "Gateway Options:"
        puts "  -p, --port PORT      Gateway port (default: #{DEFAULT_PORT})\n\n"
        puts "Cron Options:"
        puts "  -a, --all            Include disabled jobs in list"
        puts "  -n, --name NAME      Job name"
        puts "  -m, --message MSG    Message for agent"
        puts "  -e, --every SECS     Run every N seconds"
        puts "  --cron EXPR          Cron expression"
        puts "  --at TIME            Run once at ISO time"
        puts "  -d, --deliver        Deliver response to channel"
        puts "  --to DEST            Recipient for delivery"
        puts "  --channel CH         Channel for delivery"
        puts "  -f, --force          Force run (even if disabled)\n\n"
        puts "Examples:"
        puts "  autobot new optimus      # create new bot"
        puts "  autobot doctor           # check configuration"
        puts "  autobot doctor --strict  # fail on warnings"
        puts "  autobot agent -m \"Hello!\""
        puts "  autobot agent            # interactive mode"
        puts "  autobot gateway -p 8080"
        puts "  autobot cron list"
        puts "  autobot cron add -n daily_check -m \"Check system\" --cron \"0 9 * * *\""
        puts "  autobot status"
      end
    end
  end
end
