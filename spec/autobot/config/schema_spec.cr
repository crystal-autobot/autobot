require "../../spec_helper"

private def empty_config
  Autobot::Config::Config.from_yaml("--- {}")
end

private def config_with_provider
  Autobot::Config::Config.from_yaml(<<-YAML
  providers:
    anthropic:
      api_key: "test-key"
  YAML
  )
end

describe Autobot::Config::Config do
  describe ".from_yaml" do
    it "creates config with nil sections from empty YAML" do
      config = empty_config
      config.agents.should be_nil
      config.channels.should be_nil
      config.providers.should be_nil
    end

    it "parses minimal YAML config" do
      config = config_with_provider
      config.providers.try(&.anthropic.try(&.api_key)).should eq("test-key")
    end

    it "parses channel configuration" do
      yaml = <<-YAML
      channels:
        telegram:
          enabled: true
          token: "bot-token"
          allow_from:
            - "user1"
            - "user2"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      tg = config.channels.try(&.telegram)
      tg.should_not be_nil
      tg.try(&.enabled?).should be_true
      tg.try(&.token).should eq("bot-token")
      tg.try(&.allow_from).should eq(["user1", "user2"])
    end

    it "parses custom commands with simple string format" do
      yaml = <<-YAML
      channels:
        telegram:
          enabled: true
          token: "token"
          custom_commands:
            macros:
              summarize: "Summarize the conversation"
            scripts:
              deploy: "/path/to/deploy.sh"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      cmds = config.channels.try(&.telegram.try(&.custom_commands))
      cmds.should_not be_nil
      cmds.try(&.macros["summarize"]?.try(&.value)).should eq("Summarize the conversation")
      cmds.try(&.macros["summarize"]?.try(&.description)).should be_nil
      cmds.try(&.scripts["deploy"]?.try(&.value)).should eq("/path/to/deploy.sh")
      cmds.try(&.scripts["deploy"]?.try(&.description)).should be_nil
    end

    it "parses custom commands with rich format including descriptions" do
      yaml = <<-YAML
      channels:
        telegram:
          enabled: true
          token: "token"
          custom_commands:
            macros:
              summarize:
                prompt: "Summarize the conversation"
                description: "Summarize chat in bullet points"
            scripts:
              deploy:
                path: "/path/to/deploy.sh"
                description: "Deploy to production"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      cmds = config.channels.try(&.telegram.try(&.custom_commands))
      cmds.should_not be_nil
      cmds.try(&.macros["summarize"]?.try(&.value)).should eq("Summarize the conversation")
      cmds.try(&.macros["summarize"]?.try(&.description)).should eq("Summarize chat in bullet points")
      cmds.try(&.scripts["deploy"]?.try(&.value)).should eq("/path/to/deploy.sh")
      cmds.try(&.scripts["deploy"]?.try(&.description)).should eq("Deploy to production")
    end

    it "parses custom commands with mixed formats" do
      yaml = <<-YAML
      channels:
        telegram:
          enabled: true
          token: "token"
          custom_commands:
            macros:
              summarize: "Summarize the conversation"
              translate:
                prompt: "Translate the following to English"
                description: "Translate text to English"
            scripts:
              deploy: "/path/to/deploy.sh"
              status:
                path: "/path/to/status.sh"
                description: "Check system status"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      cmds = config.channels.try(&.telegram.try(&.custom_commands))
      cmds.should_not be_nil

      cmds.try(&.macros["summarize"]?.try(&.value)).should eq("Summarize the conversation")
      cmds.try(&.macros["summarize"]?.try(&.description)).should be_nil
      cmds.try(&.macros["translate"]?.try(&.value)).should eq("Translate the following to English")
      cmds.try(&.macros["translate"]?.try(&.description)).should eq("Translate text to English")

      cmds.try(&.scripts["deploy"]?.try(&.value)).should eq("/path/to/deploy.sh")
      cmds.try(&.scripts["deploy"]?.try(&.description)).should be_nil
      cmds.try(&.scripts["status"]?.try(&.value)).should eq("/path/to/status.sh")
      cmds.try(&.scripts["status"]?.try(&.description)).should eq("Check system status")
    end

    it "parses agent defaults" do
      yaml = <<-YAML
      agents:
        defaults:
          model: "openai/gpt-4"
          max_tokens: 4096
          temperature: 0.5
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      defaults = config.agents.try(&.defaults)
      defaults.should_not be_nil
      defaults.try(&.model).should eq("openai/gpt-4")
      defaults.try(&.max_tokens).should eq(4096)
      defaults.try(&.temperature).should eq(0.5)
    end

    it "parses tool settings" do
      yaml = <<-YAML
      tools:
        exec:
          timeout: 120
        sandbox: "bubblewrap"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      config.tools.try(&.exec.try(&.timeout)).should eq(120)
      config.tools.try(&.sandbox).should eq("bubblewrap")
    end
  end

  describe "#workspace_path" do
    it "expands home directory with defaults" do
      config = empty_config
      path = config.workspace_path
      path.to_s.should_not contain("~")
      path.to_s.should contain("autobot")
    end
  end

  describe "#default_model" do
    it "returns default when no agents configured" do
      config = empty_config
      config.default_model.should eq("anthropic/claude-sonnet-4-5")
    end

    it "returns configured model" do
      yaml = <<-YAML
      agents:
        defaults:
          model: "openai/gpt-4"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      config.default_model.should eq("openai/gpt-4")
    end
  end

  describe "#match_provider" do
    it "returns nil when no providers configured" do
      config = empty_config
      provider_config, provider_name = config.match_provider("anthropic/claude")
      provider_config.should be_nil
      provider_name.should be_nil
    end

    it "matches provider by model name" do
      yaml = <<-YAML
      providers:
        anthropic:
          api_key: "ant-key"
        openai:
          api_key: "oai-key"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      provider_config, provider_name = config.match_provider("anthropic/claude-3")
      provider_config.should_not be_nil
      provider_name.should eq("anthropic")
    end

    it "falls back to first provider with API key" do
      config = config_with_provider
      provider_config, provider_name = config.match_provider("unknown-model")
      provider_config.should_not be_nil
      provider_name.should eq("anthropic")
    end

    it "returns nil for bedrock models" do
      yaml = <<-YAML
      providers:
        anthropic:
          api_key: "ant-key"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      provider_config, provider_name = config.match_provider("bedrock/anthropic.claude-3")
      provider_config.should be_nil
      provider_name.should be_nil
    end
  end

  describe "#match_bedrock" do
    it "returns nil when no bedrock configured" do
      config = empty_config
      config.match_bedrock.should be_nil
    end

    it "returns nil for non-bedrock model" do
      yaml = <<-YAML
      providers:
        bedrock:
          access_key_id: "AKIAIOSFODNN7EXAMPLE"
          secret_access_key: "secret"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      config.match_bedrock("anthropic/claude-3").should be_nil
    end

    it "returns config for bedrock model with prefix" do
      yaml = <<-YAML
      agents:
        defaults:
          model: "bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0"
      providers:
        bedrock:
          access_key_id: "AKIAIOSFODNN7EXAMPLE"
          secret_access_key: "secret"
          region: "eu-west-1"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      bedrock = config.match_bedrock
      bedrock.should_not be_nil
      bedrock.try(&.region).should eq("eu-west-1")
    end

    it "returns nil when bedrock credentials are empty" do
      yaml = <<-YAML
      agents:
        defaults:
          model: "bedrock/anthropic.claude-3"
      providers:
        bedrock:
          access_key_id: ""
          secret_access_key: ""
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      config.match_bedrock.should be_nil
    end
  end

  describe "#provider_by_name" do
    it "returns nil when no providers configured" do
      config = empty_config
      config.provider_by_name("openai").should be_nil
    end

    it "finds provider by name" do
      yaml = <<-YAML
      providers:
        openai:
          api_key: "oai-key"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      provider = config.provider_by_name("openai")
      provider.should_not be_nil
      provider.try(&.api_key).should eq("oai-key")
    end

    it "is case-insensitive" do
      yaml = <<-YAML
      providers:
        gemini:
          api_key: "gem-key"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      config.provider_by_name("Gemini").should_not be_nil
      config.provider_by_name("GEMINI").should_not be_nil
    end

    it "returns nil for provider with empty api_key" do
      yaml = <<-YAML
      providers:
        openai:
          api_key: ""
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      config.provider_by_name("openai").should be_nil
    end

    it "returns nil for unknown provider name" do
      config = config_with_provider
      config.provider_by_name("unknown").should be_nil
    end
  end

  describe "#validate!" do
    it "raises when no provider has API key" do
      config = empty_config
      expect_raises(Exception, /No LLM provider configured/) do
        config.validate!
      end
    end

    it "passes when a provider has API key" do
      config = config_with_provider
      config.validate! # should not raise
    end

    it "passes when only bedrock is configured" do
      yaml = <<-YAML
      providers:
        bedrock:
          access_key_id: "AKIAIOSFODNN7EXAMPLE"
          secret_access_key: "secret"
      YAML

      config = Autobot::Config::Config.from_yaml(yaml)
      config.validate! # should not raise
    end
  end
end

describe Autobot::Config::AgentDefaults do
  it "has sensible default values" do
    defaults = Autobot::Config::AgentDefaults.from_yaml("--- {}")
    defaults.model.should eq("anthropic/claude-sonnet-4-5")
    defaults.max_tokens.should eq(8192)
    defaults.temperature.should eq(0.7)
    defaults.max_tool_iterations.should eq(20)
    defaults.memory_window.should eq(50)
  end
end

describe Autobot::Config::TelegramConfig do
  it "is disabled by default" do
    tg = Autobot::Config::TelegramConfig.from_yaml("--- {}")
    tg.enabled?.should be_false
    tg.token.should eq("")
    tg.allow_from.should be_empty
  end
end

describe Autobot::Config::CustomCommandEntry do
  it "parses from a simple string" do
    entry = Autobot::Config::CustomCommandEntry.from_yaml(%("hello world"))
    entry.value.should eq("hello world")
    entry.description.should be_nil
  end

  it "parses from a mapping with prompt key" do
    yaml = <<-YAML
    prompt: "Summarize the conversation"
    description: "Summarize chat"
    YAML

    entry = Autobot::Config::CustomCommandEntry.from_yaml(yaml)
    entry.value.should eq("Summarize the conversation")
    entry.description.should eq("Summarize chat")
  end

  it "parses from a mapping with path key" do
    yaml = <<-YAML
    path: "/path/to/script.sh"
    description: "Run a script"
    YAML

    entry = Autobot::Config::CustomCommandEntry.from_yaml(yaml)
    entry.value.should eq("/path/to/script.sh")
    entry.description.should eq("Run a script")
  end

  it "parses from a mapping without description" do
    yaml = <<-YAML
    prompt: "Do something"
    YAML

    entry = Autobot::Config::CustomCommandEntry.from_yaml(yaml)
    entry.value.should eq("Do something")
    entry.description.should be_nil
  end
end

describe Autobot::Config::CustomCommandsConfig do
  it "has empty defaults" do
    config = Autobot::Config::CustomCommandsConfig.from_yaml("--- {}")
    config.macros.should be_empty
    config.scripts.should be_empty
  end
end

describe Autobot::Config::ImageConfig do
  it "has correct defaults" do
    config = Autobot::Config::ImageConfig.from_yaml("--- {}")
    config.enabled?.should be_true
    config.provider.should be_nil
    config.model.should be_nil
    config.size.should eq("1024x1024")
  end

  it "parses all fields" do
    yaml = <<-YAML
    enabled: false
    provider: openai
    model: gpt-image-1
    size: 512x512
    YAML

    config = Autobot::Config::ImageConfig.from_yaml(yaml)
    config.enabled?.should be_false
    config.provider.should eq("openai")
    config.model.should eq("gpt-image-1")
    config.size.should eq("512x512")
  end
end

describe Autobot::Config::ToolsConfig do
  it "parses image config" do
    yaml = <<-YAML
    image:
      enabled: true
      provider: gemini
    YAML

    config = Autobot::Config::ToolsConfig.from_yaml(yaml)
    config.image.should_not be_nil
    config.image.try(&.provider).should eq("gemini")
  end

  it "has nil image config by default" do
    config = Autobot::Config::ToolsConfig.from_yaml("--- {}")
    config.image.should be_nil
  end
end

describe Autobot::Config::ProviderConfig do
  it "has empty API key by default" do
    pc = Autobot::Config::ProviderConfig.from_yaml("--- {}")
    pc.api_key.should eq("")
    pc.api_base?.should be_nil
  end
end

describe Autobot::Config::BedrockProviderConfig do
  it "has empty defaults" do
    cfg = Autobot::Config::BedrockProviderConfig.from_yaml("--- {}")
    cfg.access_key_id.should eq("")
    cfg.secret_access_key.should eq("")
    cfg.region.should eq("us-east-1")
    cfg.configured?.should be_false
  end

  it "is configured when credentials are present" do
    yaml = <<-YAML
    access_key_id: "AKIAIOSFODNN7EXAMPLE"
    secret_access_key: "secret"
    YAML

    cfg = Autobot::Config::BedrockProviderConfig.from_yaml(yaml)
    cfg.configured?.should be_true
  end

  it "is not configured when access_key_id is empty" do
    yaml = <<-YAML
    access_key_id: ""
    secret_access_key: "secret"
    YAML

    cfg = Autobot::Config::BedrockProviderConfig.from_yaml(yaml)
    cfg.configured?.should be_false
  end

  it "parses optional guardrail settings" do
    yaml = <<-YAML
    access_key_id: "AKIAIOSFODNN7EXAMPLE"
    secret_access_key: "secret"
    guardrail_id: "gr-123"
    guardrail_version: "1"
    YAML

    cfg = Autobot::Config::BedrockProviderConfig.from_yaml(yaml)
    cfg.guardrail_id.should eq("gr-123")
    cfg.guardrail_version.should eq("1")
  end
end
