require "../../spec_helper"

describe Autobot::CLI::InteractiveSetup do
  describe ".run" do
    it "collects provider and API key" do
      input = IO::Memory.new("1\nsk-ant-test123\n0\n")
      output = IO::Memory.new

      config = Autobot::CLI::InteractiveSetup.run(input, output)

      config.provider.should eq("anthropic")
      config.api_key.should eq("sk-ant-test123")
      config.channels.should be_empty
    end

    it "collects multiple channels" do
      input = IO::Memory.new("2\nsk-openai-test\n1 2\nbot-token\nxoxb-slack\nxapp-slack\n")
      output = IO::Memory.new

      config = Autobot::CLI::InteractiveSetup.run(input, output)

      config.provider.should eq("openai")
      config.api_key.should eq("sk-openai-test")
      config.channels.should eq(["telegram", "slack"])
      config.telegram_token.should eq("bot-token")
      config.slack_bot_token.should eq("xoxb-slack")
      config.slack_app_token.should eq("xapp-slack")
    end

    it "handles CLI only mode (no channels)" do
      input = IO::Memory.new("1\nsk-test\n0\n")
      output = IO::Memory.new

      config = Autobot::CLI::InteractiveSetup.run(input, output)

      config.channels.should be_empty
      config.telegram_token.should be_nil
    end

    it "handles empty API key" do
      input = IO::Memory.new("3\n\n0\n")
      output = IO::Memory.new

      config = Autobot::CLI::InteractiveSetup.run(input, output)

      config.provider.should eq("deepseek")
      config.api_key.should eq("")
    end
  end

  describe ".prompt_provider" do
    it "returns selected provider key" do
      input = IO::Memory.new("1\n")
      output = IO::Memory.new

      result = Autobot::CLI::InteractiveSetup.prompt_provider(input, output)

      result.should eq("anthropic")
    end

    it "retries on invalid input" do
      input = IO::Memory.new("99\nabc\n2\n")
      output = IO::Memory.new

      result = Autobot::CLI::InteractiveSetup.prompt_provider(input, output)

      result.should eq("openai")
      output.to_s.should contain("✗ Invalid choice")
    end
  end

  describe ".prompt_channels" do
    it "returns empty array for CLI only" do
      input = IO::Memory.new("0\n")
      output = IO::Memory.new

      result = Autobot::CLI::InteractiveSetup.prompt_channels(input, output)

      result.should be_empty
    end

    it "returns selected channels" do
      input = IO::Memory.new("1 3\n")
      output = IO::Memory.new

      result = Autobot::CLI::InteractiveSetup.prompt_channels(input, output)

      result.should eq(["telegram", "whatsapp"])
    end

    it "handles multiple spaces and invalid numbers" do
      input = IO::Memory.new("1  99  2\n")
      output = IO::Memory.new

      result = Autobot::CLI::InteractiveSetup.prompt_channels(input, output)

      result.should eq(["telegram", "slack"])
    end
  end

  describe ".prompt_channel_config" do
    it "collects Telegram token" do
      input = IO::Memory.new("7001234567:AAHtoken123\n")
      output = IO::Memory.new
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "anthropic",
        api_key: "sk-test",
        channels: ["telegram"]
      )

      Autobot::CLI::InteractiveSetup.prompt_channel_config("telegram", config, input, output)

      config.telegram_token.should eq("7001234567:AAHtoken123")
    end

    it "collects Slack tokens" do
      input = IO::Memory.new("xoxb-bot-token\nxapp-app-token\n")
      output = IO::Memory.new
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "anthropic",
        api_key: "sk-test",
        channels: ["slack"]
      )

      Autobot::CLI::InteractiveSetup.prompt_channel_config("slack", config, input, output)

      config.slack_bot_token.should eq("xoxb-bot-token")
      config.slack_app_token.should eq("xapp-app-token")
    end

    it "uses default WhatsApp bridge URL when empty" do
      input = IO::Memory.new("\n")
      output = IO::Memory.new
      config = Autobot::CLI::InteractiveSetup::Configuration.new(
        provider: "anthropic",
        api_key: "sk-test",
        channels: ["whatsapp"]
      )

      Autobot::CLI::InteractiveSetup.prompt_channel_config("whatsapp", config, input, output)

      config.whatsapp_bridge_url.should eq("ws://localhost:3001")
    end
  end
end
