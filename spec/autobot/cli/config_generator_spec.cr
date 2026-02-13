require "../../spec_helper"

describe Autobot::CLI::ConfigGenerator do
  describe ".generate_env" do
    it "generates env file with provider API key" do
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "anthropic",
        api_key: "sk-ant-test123"
      )

      result = Autobot::CLI::ConfigGenerator.generate_env(config)

      result.should contain("ANTHROPIC_API_KEY=sk-ant-test123")
    end

    it "includes channel tokens when channels are configured" do
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "anthropic",
        api_key: "sk-ant-test",
        channels: ["telegram"],
        telegram_token: "123:ABC"
      )

      result = Autobot::CLI::ConfigGenerator.generate_env(config)

      result.should contain("TELEGRAM_BOT_TOKEN=123:ABC")
    end

    it "skips empty channel tokens" do
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "anthropic",
        api_key: "sk-ant-test",
        channels: ["telegram"],
        telegram_token: ""
      )

      result = Autobot::CLI::ConfigGenerator.generate_env(config)

      result.should_not contain("TELEGRAM_BOT_TOKEN")
    end
  end

  describe ".generate_config" do
    it "generates valid YAML configuration" do
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "anthropic",
        api_key: "sk-ant-test"
      )

      result = Autobot::CLI::ConfigGenerator.generate_config(config)

      result.should contain("providers:")
      result.should contain("anthropic:")
      result.should contain("api_key: \"${ANTHROPIC_API_KEY}\"")
      result.should contain("model: \"anthropic/claude-sonnet-4-5\"")
    end

    it "includes channel configuration when channels are enabled" do
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "openai",
        api_key: "sk-test",
        channels: ["slack"]
      )

      result = Autobot::CLI::ConfigGenerator.generate_config(config)

      result.should contain("channels:")
      result.should contain("slack:")
      result.should contain("enabled: true")
    end
  end
end
