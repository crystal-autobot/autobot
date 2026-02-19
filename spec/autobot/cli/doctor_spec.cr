require "../../spec_helper"

# Helper to capture Doctor output and reset IO after each test
private def with_doctor_io(&)
  io = IO::Memory.new
  Autobot::CLI::Doctor.io = io
  begin
    yield io
  ensure
    Autobot::CLI::Doctor.io = STDOUT
  end
end

private def make_config(yaml : String) : Autobot::Config::Config
  Autobot::Config::Config.from_yaml(yaml)
end

describe Autobot::CLI::Doctor do
  describe ".check_env_file" do
    it "warns when .env file is missing" do
      with_doctor_io do |io|
        errors, warnings = Autobot::CLI::Doctor.check_env_file(Path["/nonexistent/.env"], 0, 0)

        errors.should eq(0)
        warnings.should eq(1)
        io.to_s.should contain(".env file not found")
        io.to_s.should_not contain("✗")
        io.to_s.should contain("!")
      end
    end

    it "passes when .env file exists with secure permissions" do
      tmp = TestHelper.tmp_dir
      env_file = tmp / ".env"
      File.write(env_file, "KEY=value")
      File.chmod(env_file, 0o600)

      with_doctor_io do |io|
        errors, warnings = Autobot::CLI::Doctor.check_env_file(env_file, 0, 0)

        errors.should eq(0)
        warnings.should eq(0)
        io.to_s.should contain("✓ .env file found")
        io.to_s.should contain("✓ .env permissions secure")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails when .env file has insecure permissions" do
      tmp = TestHelper.tmp_dir
      env_file = tmp / ".env"
      File.write(env_file, "KEY=value")
      File.chmod(env_file, 0o644)

      with_doctor_io do |io|
        errors, warnings = Autobot::CLI::Doctor.check_env_file(env_file, 0, 0)

        errors.should eq(1)
        warnings.should eq(0)
        io.to_s.should contain("✗ .env has insecure permissions")
        io.to_s.should contain("chmod 600")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe ".check_plaintext_secrets" do
    it "passes when config has no plaintext secrets" do
      tmp = TestHelper.tmp_dir
      config_file = tmp / "config.yml"
      File.write(config_file, <<-YAML
      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
      YAML
      )

      with_doctor_io do |io|
        errors = Autobot::CLI::Doctor.check_plaintext_secrets(config_file, 0)

        errors.should eq(0)
        io.to_s.should contain("✓ No plaintext secrets")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails when config has plaintext Anthropic key" do
      tmp = TestHelper.tmp_dir
      config_file = tmp / "config.yml"
      File.write(config_file, <<-YAML
      providers:
        anthropic:
          api_key: "sk-ant-api03-realkey123456789012345678"
      YAML
      )

      with_doctor_io do |io|
        errors = Autobot::CLI::Doctor.check_plaintext_secrets(config_file, 0)

        errors.should eq(1)
        io.to_s.should contain("✗ Plaintext secrets detected")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe ".check_provider" do
    it "passes when a provider is configured" do
      config = make_config(<<-YAML
      providers:
        anthropic:
          api_key: "real-key-here"
      YAML
      )

      with_doctor_io do |io|
        errors = Autobot::CLI::Doctor.check_provider(config, 0)

        errors.should eq(0)
        io.to_s.should contain("✓ LLM provider configured (anthropic)")
      end
    end

    it "fails when no provider is configured" do
      config = make_config(<<-YAML
      providers:
        anthropic:
          api_key: ""
      YAML
      )

      with_doctor_io do |io|
        errors = Autobot::CLI::Doctor.check_provider(config, 0)

        errors.should eq(1)
        io.to_s.should contain("✗ No LLM provider configured")
        io.to_s.should contain("ANTHROPIC_API_KEY")
      end
    end
  end

  describe ".check_security_settings" do
    it "passes when sandbox is available" do
      config = make_config(<<-YAML
      tools:
        sandbox: "auto"
      YAML
      )

      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::Bubblewrap
      with_doctor_io do |io|
        errors = Autobot::CLI::Doctor.check_security_settings(config, 0)

        errors.should eq(0)
        io.to_s.should contain("✓ Sandbox available")
      end
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end
  end

  describe ".check_telegram" do
    it "skips when telegram is disabled" do
      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_telegram(nil, 0)

        warnings.should eq(0)
        io.to_s.should contain("— Telegram (disabled)")
      end
    end

    it "warns when telegram is enabled but token is unset" do
      telegram = Autobot::Config::TelegramConfig.from_yaml(<<-YAML
      enabled: true
      token: "${TELEGRAM_BOT_TOKEN}"
      allow_from: []
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_telegram(telegram, 0)

        warnings.should eq(1)
        io.to_s.should contain("! Telegram enabled but token not set")
      end
    end

    it "warns when telegram is enabled but allow_from is empty" do
      telegram = Autobot::Config::TelegramConfig.from_yaml(<<-YAML
      enabled: true
      token: "123456:ABC-DEF"
      allow_from: []
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_telegram(telegram, 0)

        warnings.should eq(1)
        io.to_s.should contain("! Telegram enabled but allow_from is empty")
      end
    end

    it "passes when telegram is fully configured" do
      telegram = Autobot::Config::TelegramConfig.from_yaml(<<-YAML
      enabled: true
      token: "123456:ABC-DEF"
      allow_from: ["12345"]
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_telegram(telegram, 0)

        warnings.should eq(0)
        io.to_s.should contain("✓ Telegram configured")
      end
    end
  end

  describe ".check_slack" do
    it "skips when slack is disabled" do
      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_slack(nil, 0)

        warnings.should eq(0)
        io.to_s.should contain("— Slack (disabled)")
      end
    end

    it "warns when slack is enabled but bot_token is unset" do
      slack = Autobot::Config::SlackConfig.from_yaml(<<-YAML
      enabled: true
      bot_token: "${SLACK_BOT_TOKEN}"
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_slack(slack, 0)

        warnings.should eq(1)
        io.to_s.should contain("! Slack enabled but bot_token not set")
      end
    end

    it "passes when slack is fully configured" do
      slack = Autobot::Config::SlackConfig.from_yaml(<<-YAML
      enabled: true
      bot_token: "xoxb-real-token"
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_slack(slack, 0)

        warnings.should eq(0)
        io.to_s.should contain("✓ Slack configured")
      end
    end
  end

  describe ".check_whatsapp" do
    it "skips when whatsapp is disabled" do
      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_whatsapp(nil, 0)

        warnings.should eq(0)
        io.to_s.should contain("— WhatsApp (disabled)")
      end
    end

    it "warns when whatsapp is enabled but allow_from is empty" do
      whatsapp = Autobot::Config::WhatsAppConfig.from_yaml(<<-YAML
      enabled: true
      allow_from: []
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_whatsapp(whatsapp, 0)

        warnings.should eq(1)
        io.to_s.should contain("! WhatsApp enabled but allow_from is empty")
      end
    end
  end

  describe ".check_voice_transcription" do
    it "skips when no providers configured" do
      config = make_config("{}")

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_voice_transcription(config)

        io.to_s.should contain("— Voice transcription (no openai/groq provider)")
      end
    end

    it "passes when groq is configured" do
      config = make_config(<<-YAML
      providers:
        groq:
          api_key: "gsk-test-key"
      YAML
      )

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_voice_transcription(config)

        io.to_s.should contain("✓ Voice transcription available (groq)")
      end
    end

    it "passes when openai is configured" do
      config = make_config(<<-YAML
      providers:
        openai:
          api_key: "sk-test-key"
      YAML
      )

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_voice_transcription(config)

        io.to_s.should contain("✓ Voice transcription available (openai)")
      end
    end

    it "prefers groq over openai" do
      config = make_config(<<-YAML
      providers:
        groq:
          api_key: "gsk-test-key"
        openai:
          api_key: "sk-test-key"
      YAML
      )

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_voice_transcription(config)

        io.to_s.should contain("✓ Voice transcription available (groq)")
      end
    end

    it "skips when provider has empty api_key" do
      config = make_config(<<-YAML
      providers:
        openai:
          api_key: ""
      YAML
      )

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_voice_transcription(config)

        io.to_s.should contain("— Voice transcription (no openai/groq provider)")
      end
    end
  end

  describe ".check_web_search" do
    it "skips when no tools configured" do
      config = make_config("{}")

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_web_search(config)

        io.to_s.should contain("— Web search (no BRAVE_API_KEY)")
      end
    end

    it "passes when brave api key is configured" do
      config = make_config(<<-YAML
      tools:
        web:
          search:
            api_key: "BSA-test-key"
      YAML
      )

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_web_search(config)

        io.to_s.should contain("✓ Web search available (brave)")
      end
    end

    it "skips when api key is empty" do
      config = make_config(<<-YAML
      tools:
        web:
          search:
            api_key: ""
      YAML
      )

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_web_search(config)

        io.to_s.should contain("— Web search (no BRAVE_API_KEY)")
      end
    end

    it "skips when api key is unresolved env var" do
      config = make_config(<<-YAML
      tools:
        web:
          search:
            api_key: "${BRAVE_API_KEY}"
      YAML
      )

      with_doctor_io do |io|
        Autobot::CLI::Doctor.check_web_search(config)

        io.to_s.should contain("— Web search (no BRAVE_API_KEY)")
      end
    end
  end

  describe ".check_gateway" do
    it "skips when gateway is not configured" do
      config = make_config("{}")

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_gateway(config, 0)

        warnings.should eq(0)
        io.to_s.should contain("— Gateway (not configured)")
      end
    end

    it "warns when gateway is bound to all interfaces" do
      config = make_config(<<-YAML
      gateway:
        host: "0.0.0.0"
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_gateway(config, 0)

        warnings.should eq(1)
        io.to_s.should contain("! Gateway bound to 0.0.0.0")
      end
    end

    it "passes when gateway is bound to localhost" do
      config = make_config(<<-YAML
      gateway:
        host: "127.0.0.1"
      YAML
      )

      with_doctor_io do |io|
        warnings = Autobot::CLI::Doctor.check_gateway(config, 0)

        warnings.should eq(0)
        io.to_s.should contain("✓ Gateway bound to 127.0.0.1")
      end
    end
  end

  describe ".print_summary" do
    it "shows all checks passed when no issues" do
      with_doctor_io do |io|
        Autobot::CLI::Doctor.print_summary(0, 0, false)

        io.to_s.should contain("All checks passed!")
      end
    end

    it "shows warnings count when only warnings" do
      with_doctor_io do |io|
        Autobot::CLI::Doctor.print_summary(0, 2, false)

        io.to_s.should contain("2 warnings. All good otherwise!")
      end
    end

    it "shows singular warning" do
      with_doctor_io do |io|
        Autobot::CLI::Doctor.print_summary(0, 1, false)

        io.to_s.should contain("1 warning. All good otherwise!")
      end
    end

    it "shows errors and warnings" do
      with_doctor_io do |io|
        Autobot::CLI::Doctor.print_summary(2, 1, false)

        io.to_s.should contain("2 errors, 1 warning found.")
      end
    end

    it "shows strict mode note when warnings in strict mode" do
      with_doctor_io do |io|
        Autobot::CLI::Doctor.print_summary(0, 1, true)

        io.to_s.should contain("1 warning found.")
        io.to_s.should contain("--strict")
      end
    end
  end

  describe ".pluralize" do
    it "returns singular form for count 1" do
      Autobot::CLI::Doctor.pluralize("error", 1).should eq("1 error")
    end

    it "returns plural form for count > 1" do
      Autobot::CLI::Doctor.pluralize("error", 3).should eq("3 errors")
    end

    it "returns plural form for count 0" do
      Autobot::CLI::Doctor.pluralize("warning", 0).should eq("0 warnings")
    end
  end
end
