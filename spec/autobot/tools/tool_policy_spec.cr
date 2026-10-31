require "../../spec_helper"

private alias Capability = Autobot::Tools::Capability
private alias ToolPolicy = Autobot::Tools::ToolPolicy

describe Autobot::Tools::ToolPolicy do
  describe ".gateway" do
    it "grants everything except host exec by default" do
      policy = ToolPolicy.gateway
      policy.granted.should eq(Capability::All & ~Capability::HostExec)
      policy.host_exec?.should be_false
    end

    it "swaps sandboxed exec for host exec when asked" do
      policy = ToolPolicy.gateway(host_exec: true)
      policy.host_exec?.should be_true
      policy.granted.sandboxed_exec?.should be_false
    end

    it "only narrows with explicit capabilities" do
      policy = ToolPolicy.gateway(capabilities: Capability::WorkspaceRead | Capability::HostExec)
      policy.granted.should eq(Capability::WorkspaceRead)
    end
  end

  describe "#background" do
    it "drops delegation and keeps the rest" do
      background = ToolPolicy.gateway(host_exec: true).background
      background.granted.delegation?.should be_false
      background.host_exec?.should be_true
    end
  end

  describe "#permits?" do
    it "requires every bit to be granted and always permits none" do
      policy = ToolPolicy.gateway
      policy.permits?(Capability::None).should be_true
      policy.permits?(Capability::WorkspaceRead | Capability::WebRead).should be_true
      policy.permits?(Capability::WorkspaceRead | Capability::HostExec).should be_false
    end
  end
end
