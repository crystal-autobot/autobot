require "./capability"

module Autobot::Tools
  record ToolPolicy, granted : Capability do
    def self.gateway(host_exec : Bool = false, capabilities : Capability = Capability::All) : ToolPolicy
      granted = Capability::All & ~Capability::HostExec
      granted = (granted & ~Capability::SandboxedExec) | Capability::HostExec if host_exec
      new(granted & capabilities)
    end

    def background : ToolPolicy
      ToolPolicy.new(granted & ~Capability::Delegation)
    end

    def permits?(capabilities : Capability) : Bool
      (capabilities & ~granted).none?
    end

    def host_exec? : Bool
      granted.host_exec?
    end
  end
end
