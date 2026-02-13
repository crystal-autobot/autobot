require "../../spec_helper"

module SetupHelperSpecHelper
  def self.create_test_config
    config_yaml = <<-YAML
    agents:
      defaults:
        workspace: "/tmp/test-workspace"
        model: "anthropic/claude-sonnet-4-5"

    providers:
      anthropic:
        api_key: "sk-test"

    tools:
      sandbox: "none"
    YAML

    Autobot::Config::Config.from_yaml(config_yaml)
  end
end

describe Autobot::CLI::SetupHelper do
  describe ".setup_tools" do
    it "creates tool registry with built-in tools" do
      config = SetupHelperSpecHelper.create_test_config

      tool_registry, plugin_registry = Autobot::CLI::SetupHelper.setup_tools(config)

      tool_registry.should_not be_nil
      tool_registry.size.should be > 0
      plugin_registry.should_not be_nil
    end

    it "registers expected tools" do
      config = SetupHelperSpecHelper.create_test_config

      tool_registry, _plugin_registry = Autobot::CLI::SetupHelper.setup_tools(config)

      # Should have file tools
      tool_registry.get("read_file").should_not be_nil
      tool_registry.get("write_file").should_not be_nil
      tool_registry.get("list_dir").should_not be_nil

      # Should have exec tool
      tool_registry.get("exec").should_not be_nil

      # Should have web tools
      tool_registry.get("web_search").should_not be_nil
      tool_registry.get("web_fetch").should_not be_nil
    end
  end
end
