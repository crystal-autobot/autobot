module Autobot::Tools
  @[Flags]
  enum Capability
    WorkspaceRead
    WorkspaceWrite
    SandboxedExec
    HostExec
    WebRead
    Messaging
    Scheduling
    Delegation
    ExternalApi

    def self.from_config(names : Array(String)) : Capability
      return All if names.empty?

      names.reduce(None) { |granted, name| granted | parse_config(name) }
    end

    private def self.parse_config(name : String) : Capability
      capability = parse?(name.strip) || raise ArgumentError.new(
        "unknown capability '#{name}' (use: #{All.config_names.join(", ")})"
      )
      if capability.host_exec?
        raise ArgumentError.new("host_exec cannot be granted here; set tools.sandbox: none explicitly instead")
      end
      capability
    end

    def config_names : Array(String)
      names = [] of String
      each { |member, _| names << member.config_name }
      names
    end

    def config_name : String
      to_s.underscore
    end
  end
end
