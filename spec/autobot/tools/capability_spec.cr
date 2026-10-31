require "../../spec_helper"

private alias Capability = Autobot::Tools::Capability

describe Autobot::Tools::Capability do
  describe ".from_config" do
    it "grants everything for an empty list" do
      Capability.from_config([] of String).should eq(Capability::All)
    end

    it "combines the listed names" do
      Capability.from_config(["workspace_read", " Web_Read "]).should eq(Capability::WorkspaceRead | Capability::WebRead)
    end

    it "rejects unknown and host_exec entries" do
      expect_raises(ArgumentError, /unknown capability 'bash' \(use: workspace_read/) do
        Capability.from_config(["bash"])
      end
      expect_raises(ArgumentError, /host_exec cannot be granted here; set tools.sandbox: none/) do
        Capability.from_config(["host_exec"])
      end
    end
  end

  it "renders config names" do
    caps = Capability::WorkspaceWrite | Capability::ExternalApi
    caps.config_names.should eq(["workspace_write", "external_api"])
    Capability::None.config_names.should be_empty
  end
end
