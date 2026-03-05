module Autobot
  module CLI
    module Service
      SYSTEMD_SERVICE_PATH = "/etc/systemd/system/autobot.service"
      LAUNCHD_PLIST_ID     = "com.autobot.agent"

      SYSTEMD_TEMPLATE = <<-UNIT
        [Unit]
        Description=Autobot AI Agent
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        User=%s
        Group=%s
        WorkingDirectory=%s
        EnvironmentFile=%s/.env
        ExecStart=%s gateway

        NoNewPrivileges=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=%s

        Restart=on-failure
        RestartSec=10

        StandardOutput=journal
        StandardError=journal
        SyslogIdentifier=autobot

        [Install]
        WantedBy=multi-user.target
        UNIT

      def self.run(args : Array(String)) : Nil
        case args.shift? || "help"
        when "generate"
          puts render_for_platform
        when "install"
          install
        when "help"
          print_help
        else
          STDERR.puts "Unknown subcommand. Run 'autobot service help' for usage."
          exit 1
        end
      end

      private def self.install : Nil
        {% if flag?(:linux) %}
          install_to(SYSTEMD_SERVICE_PATH, render_systemd_unit, sudo_hint: true)
          puts "\nNext steps:"
          puts "  sudo systemctl daemon-reload"
          puts "  sudo systemctl enable --now autobot"
          puts "\nCheck status:"
          puts "  sudo systemctl status autobot"
        {% elsif flag?(:darwin) %}
          plist_path = launchd_plist_path
          install_to(plist_path, render_launchd_plist)
          puts "\nNext steps:"
          puts "  launchctl load #{plist_path}"
          puts "\nCheck status:"
          puts "  launchctl list | grep autobot"
        {% else %}
          STDERR.puts "Error: service install is not supported on this platform"
          exit 1
        {% end %}
      end

      private def self.install_to(path : String, content : String, sudo_hint : Bool = false) : Nil
        File.write(path, content)
        puts "Service file written to #{path}"
      rescue ex : File::Error
        STDERR.puts "Error: cannot write to #{path}"
        STDERR.puts "Run with sudo: sudo autobot service install" if sudo_hint
        exit 1
      end

      private def self.render_for_platform : String
        {% if flag?(:darwin) %}
          render_launchd_plist
        {% else %}
          render_systemd_unit
        {% end %}
      end

      # -- Systemd --

      def self.render_systemd_unit(working_dir : String, binary_path : String, user : String) : String
        SYSTEMD_TEMPLATE % {user, user, working_dir, working_dir, binary_path, working_dir}
      end

      private def self.render_systemd_unit : String
        render_systemd_unit(Dir.current, detect_binary_path, detect_user)
      end

      # -- Launchd --

      def self.render_launchd_plist(working_dir : String, binary_path : String, env_vars : Hash(String, String)) : String
        String.build do |xml|
          xml << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
          xml << "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
          xml << "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
          xml << "<plist version=\"1.0\">\n"
          xml << "<dict>\n"
          plist_entry(xml, "Label", LAUNCHD_PLIST_ID)
          xml << "  <key>ProgramArguments</key>\n"
          xml << "  <array>\n"
          xml << "    <string>#{binary_path}</string>\n"
          xml << "    <string>gateway</string>\n"
          xml << "  </array>\n"
          plist_entry(xml, "WorkingDirectory", working_dir)
          append_env_vars(xml, env_vars)
          xml << "  <key>RunAtLoad</key>\n  <true/>\n"
          xml << "  <key>KeepAlive</key>\n  <true/>\n"
          plist_entry(xml, "StandardOutPath", "#{working_dir}/logs/autobot.log")
          plist_entry(xml, "StandardErrorPath", "#{working_dir}/logs/autobot.error.log")
          xml << "</dict>\n"
          xml << "</plist>\n"
        end
      end

      private def self.render_launchd_plist : String
        working_dir = Dir.current
        env_path = File.join(working_dir, ".env")
        render_launchd_plist(working_dir, detect_binary_path, load_env_vars(env_path))
      end

      private def self.plist_entry(xml : IO, key : String, value : String) : Nil
        xml << "  <key>#{key}</key>\n"
        xml << "  <string>#{escape_xml(value)}</string>\n"
      end

      private def self.append_env_vars(xml : IO, env_vars : Hash(String, String)) : Nil
        return if env_vars.empty?

        xml << "  <key>EnvironmentVariables</key>\n"
        xml << "  <dict>\n"
        env_vars.each do |key, value|
          xml << "    <key>#{escape_xml(key)}</key>\n"
          xml << "    <string>#{escape_xml(value)}</string>\n"
        end
        xml << "  </dict>\n"
      end

      # -- Helpers --

      def self.load_env_vars(path : String) : Hash(String, String)
        vars = {} of String => String
        return vars unless File.exists?(path)

        File.each_line(path) do |line|
          line = line.strip
          next if line.empty? || line.starts_with?('#')
          if line.includes?('=')
            key, _, value = line.partition('=')
            vars[key.strip] = value.strip.lstrip('"').rstrip('"')
          end
        end
        vars
      end

      def self.escape_xml(str : String) : String
        str.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
      end

      private def self.detect_binary_path : String
        Process.executable_path || "/usr/local/bin/autobot"
      end

      private def self.detect_user : String
        ENV.fetch("SUDO_USER", `whoami`.strip)
      end

      private def self.launchd_plist_path : String
        dir = File.join(ENV.fetch("HOME", "/tmp"), "Library/LaunchAgents")
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.join(dir, "#{LAUNCHD_PLIST_ID}.plist")
      end

      private def self.print_help : Nil
        puts "Usage: autobot service <subcommand>\n\n"
        puts "Install autobot as a system service.\n\n"
        puts "Subcommands:"
        puts "  generate    Print the service file to stdout"
        {% if flag?(:linux) %}
          puts "  install     Write the unit file to #{SYSTEMD_SERVICE_PATH} (requires sudo)"
        {% elsif flag?(:darwin) %}
          puts "  install     Write the plist to ~/Library/LaunchAgents/"
        {% else %}
          puts "  install     Install as a system service"
        {% end %}
        puts "  help        Show this help\n\n"
        puts "Run from the bot directory to auto-detect paths.\n\n"
        puts "Examples:"
        {% if flag?(:linux) %}
          puts "  autobot service generate                # preview the unit file"
          puts "  sudo autobot service install            # install systemd service"
        {% elsif flag?(:darwin) %}
          puts "  autobot service generate                # preview the plist"
          puts "  autobot service install                 # install launchd service"
        {% end %}
      end
    end
  end
end
