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
  describe ".register_builtin_plugins" do
    it "registers all builtin plugins by default" do
      Autobot::Plugins::Loader.clear_pending
      config = SetupHelperSpecHelper.create_test_config

      Autobot::CLI::SetupHelper.register_builtin_plugins(config)

      names = Autobot::Plugins::Loader.pending.map(&.name)
      names.should contain("sqlite")
      names.should contain("github")
      names.should contain("weather")
    ensure
      Autobot::Plugins::Loader.clear_pending
    end

    it "skips disabled plugins" do
      Autobot::Plugins::Loader.clear_pending
      yaml = <<-YAML
      plugins:
        sqlite:
          enabled: false
        github:
          enabled: false
      providers:
        anthropic:
          api_key: "sk-test"
      tools:
        sandbox: "none"
      YAML
      config = Autobot::Config::Config.from_yaml(yaml)

      Autobot::CLI::SetupHelper.register_builtin_plugins(config)

      names = Autobot::Plugins::Loader.pending.map(&.name)
      names.should_not contain("sqlite")
      names.should_not contain("github")
      names.should contain("weather")
    ensure
      Autobot::Plugins::Loader.clear_pending
    end

    it "registers all when plugins config is absent" do
      Autobot::Plugins::Loader.clear_pending
      config = Autobot::Config::Config.from_yaml("--- {}")

      Autobot::CLI::SetupHelper.register_builtin_plugins(config)

      Autobot::Plugins::Loader.pending.size.should eq(3)
    ensure
      Autobot::Plugins::Loader.clear_pending
    end
  end

  describe ".setup_tools" do
    it "creates tool registry with built-in tools" do
      config = SetupHelperSpecHelper.create_test_config

      tool_registry, _mcp_clients = Autobot::CLI::SetupHelper.setup_tools(config)

      tool_registry.should_not be_nil
      tool_registry.size.should be > 0
    end

    it "registers expected tools" do
      config = SetupHelperSpecHelper.create_test_config

      tool_registry, _mcp_clients = Autobot::CLI::SetupHelper.setup_tools(config)

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
