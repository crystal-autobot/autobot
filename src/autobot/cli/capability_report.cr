require "../tools/registry"
require "../tools/sandbox"
require "../mcp/proxy_tool"
require "../plugins/builtin/gh_cli"

module Autobot
  module CLI
    # Summarizes what a bot's tools may do, computed from the registry the
    # gateway would build plus the plugin and MCP configuration.
    module CapabilityReport
      HEADER      = "Capabilities (gateway profile; cron and subagents get the same minus spawn)"
      LABEL_WIDTH = 17

      record Line, status : Doctor::Status, label : String, text : String do
        def to_s(io : IO) : Nil
          io << label.ljust(LABEL_WIDTH) << text
        end
      end

      class_property container_marker_paths : Array(String) = ["/.dockerenv", "/run/.containerenv"]

      PLUGIN_TOOLS = {
        "sqlite"         => {"sqlite", "workspace db"},
        "weather"        => {"get_weather", "web"},
        "text_to_speech" => {"text_to_speech", "api, writes workspace"},
      }

      def self.build(config : Config::Config, registry : Tools::Registry, sandbox : Tools::Sandbox::Assessment) : Array(Line)
        [
          workspace_line(config, registry),
          commands_line(registry, sandbox),
          web_line(config, registry),
          chat_line(config, registry),
          external_line(config),
        ]
      end

      def self.workspace_line(config : Config::Config, registry : Tools::Registry) : Line
        modes = [] of String
        modes << "read" if registry.has?("read_file") || registry.has?("list_dir")
        modes << "write" if registry.has?("write_file") || registry.has?("edit_file")
        return line(:pass, "Workspace files", "none") if modes.empty?

        text = "#{modes.join(", ")} · #{config.workspace_path}"
        roots = config.filesystem_roots
        text += " · roots: #{roots.join(", ")}" unless roots.empty?
        line(:pass, "Workspace files", text)
      end

      def self.commands_line(registry : Tools::Registry, sandbox : Tools::Sandbox::Assessment) : Line
        type = sandbox.type
        return line(:fail, "Commands", "unavailable (invalid sandbox setting)") unless type
        return line(:fail, "Commands", "unavailable (no sandbox backend)") if sandbox.level.error? && type.none?
        return line(:pass, "Commands", "disabled") unless registry.has?("exec")

        backend_line(type, sandbox.level.error?)
      end

      private def self.backend_line(type : Tools::Sandbox::Type, missing : Bool) : Line
        name = type.to_s.downcase
        case type
        when .none?     then line(:warn, "Commands", "Host exec: enabled by sandbox: none")
        when .external? then line(:warn, "Commands", "external (not verified; #{container_marker_note})")
        else
          missing ? line(:fail, "Commands", "unavailable (#{name} not installed)") : line(:pass, "Commands", "sandboxed (#{name})")
        end
      end

      def self.web_line(config : Config::Config, registry : Tools::Registry) : Line
        parts = [] of String
        parts << "search" if registry.has?("web_search") && web_search_key?(config)
        parts << "fetch" if registry.has?("web_fetch")
        return line(:pass, "Web", "none") if parts.empty?

        domains = config.tools.try(&.web.try(&.allowed_domains)) || [] of String
        scope = domains.empty? ? "any domain" : "allowed domains: #{domains.join(", ")}"
        line(:pass, "Web", "#{parts.join(", ")} · SSRF guard · #{scope}")
      end

      def self.chat_line(config : Config::Config, registry : Tools::Registry) : Line
        granted = registry.policy.granted
        allowlist = tool_allowlist(config)
        parts = [] of String
        parts << "message" if registry.has?("message")
        parts << "cron" if granted.scheduling? && allowlist.allows?("cron")
        parts << "spawn" if granted.delegation? && allowlist.allows?("spawn")
        line(:pass, "Chat", parts.empty? ? "none" : parts.join(", "))
      end

      def self.external_line(config : Config::Config) : Line
        github = github_entry(config)
        mcp = mcp_servers(config).map { |name| "#{Mcp::ProxyTool.build_name(name, "")}* (runs on host)" }
        entries = [github].compact + mcp + plugin_entries(config)
        return line(:pass, "External", "none") if entries.empty?

        status = github || !mcp.empty? ? Doctor::Status::Warn : Doctor::Status::Pass
        line(status, "External", entries.join(" · "))
      end

      private def self.line(status : Doctor::Status, label : String, text : String) : Line
        Line.new(status, label, text)
      end

      private def self.github_entry(config : Config::Config) : String?
        return nil unless config.plugin_enabled?("github") && tool_allowlist(config).allows?("github")
        gh = Plugins::Builtin::GhCli.status
        return nil unless gh.installed

        login = Plugins::Builtin::GhCli.login if gh.logged_in
        login ? "github (gh as @#{login})" : "github (gh not logged in)"
      end

      private def self.plugin_entries(config : Config::Config) : Array(String)
        allowlist = tool_allowlist(config)
        PLUGIN_TOOLS.compact_map do |plugin, (tool, note)|
          next unless config.plugin_enabled?(plugin) && allowlist.allows?(tool)
          "#{plugin} (#{note})"
        end
      end

      private def self.mcp_servers(config : Config::Config) : Array(String)
        config.mcp.try(&.servers.keys) || [] of String
      end

      private def self.tool_allowlist(config : Config::Config) : Tools::Allowlist
        Tools::Allowlist.new(config.tools.try(&.enabled) || [] of String)
      end

      private def self.web_search_key?(config : Config::Config) : Bool
        key = config.tools.try(&.web.try(&.search.try(&.api_key))) || ""
        !key.empty? && !key.includes?("${")
      end

      private def self.container_marker_note : String
        found = container_marker_paths.any? { |path| File.exists?(path) }
        found ? "container marker found" : "no container marker found"
      end
    end
  end
end
