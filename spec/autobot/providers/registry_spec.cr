require "../../spec_helper"

describe Autobot::Providers do
  describe ".find_by_model" do
    it "matches Anthropic by model name" do
      spec = Autobot::Providers.find_by_model("anthropic/claude-sonnet-4-5")
      spec.should_not be_nil
      spec.try(&.name).should eq("anthropic")
    end

    it "matches by keyword 'claude'" do
      spec = Autobot::Providers.find_by_model("claude-opus-4-5")
      spec.should_not be_nil
      spec.try(&.name).should eq("anthropic")
    end

    it "matches OpenAI by 'gpt'" do
      spec = Autobot::Providers.find_by_model("gpt-4o")
      spec.should_not be_nil
      spec.try(&.name).should eq("openai")
    end

    it "matches DeepSeek" do
      spec = Autobot::Providers.find_by_model("deepseek-chat")
      spec.should_not be_nil
      spec.try(&.name).should eq("deepseek")
    end

    it "matches Gemini" do
      spec = Autobot::Providers.find_by_model("gemini-pro")
      spec.should_not be_nil
      spec.try(&.name).should eq("gemini")
    end

    it "matches Moonshot by 'kimi'" do
      spec = Autobot::Providers.find_by_model("kimi-k2.5")
      spec.should_not be_nil
      spec.try(&.name).should eq("moonshot")
    end

    it "matches case-insensitively" do
      spec = Autobot::Providers.find_by_model("CLAUDE-OPUS-4")
      spec.should_not be_nil
      spec.try(&.name).should eq("anthropic")
    end

    it "skips gateways" do
      spec = Autobot::Providers.find_by_model("openrouter/claude-3")
      # Should match anthropic (by 'claude' keyword), not openrouter
      spec.should_not be_nil
      spec.try(&.name).should eq("anthropic")
    end

    it "returns nil for unknown model" do
      spec = Autobot::Providers.find_by_model("unknown-model-xyz")
      spec.should be_nil
    end
  end

  describe ".find_gateway" do
    it "detects OpenRouter by API key prefix" do
      spec = Autobot::Providers.find_gateway(api_key: "sk-or-abc123")
      spec.should_not be_nil
      spec.try(&.name).should eq("openrouter")
      spec.try(&.gateway?).should be_true
    end

    it "detects AiHubMix by api_base keyword" do
      spec = Autobot::Providers.find_gateway(api_base: "https://aihubmix.com/v1")
      spec.should_not be_nil
      spec.try(&.name).should eq("aihubmix")
    end

    it "detects vLLM by explicit provider_name" do
      spec = Autobot::Providers.find_gateway(provider_name: "vllm")
      spec.should_not be_nil
      spec.try(&.name).should eq("vllm")
      spec.try(&.local?).should be_true
    end

    it "returns nil when no match" do
      spec = Autobot::Providers.find_gateway(api_key: "sk-regular-key")
      spec.should be_nil
    end

    it "prioritizes provider_name over key prefix" do
      spec = Autobot::Providers.find_gateway(
        provider_name: "vllm",
        api_key: "sk-or-abc123"
      )
      spec.should_not be_nil
      spec.try(&.name).should eq("vllm")
    end
  end

  describe ".find_by_name" do
    it "finds by exact name" do
      spec = Autobot::Providers.find_by_name("anthropic")
      spec.should_not be_nil
      spec.try(&.display_name).should eq("Anthropic")
    end

    it "returns nil for unknown name" do
      spec = Autobot::Providers.find_by_name("nonexistent")
      spec.should be_nil
    end
  end

  describe "ProviderSpec" do
    it "has correct Anthropic auth header" do
      spec = Autobot::Providers.find_by_name("anthropic")
      spec.should_not be_nil
      spec.try(&.auth_header).should eq("x-api-key")
    end

    it "has default Authorization header for OpenAI" do
      spec = Autobot::Providers.find_by_name("openai")
      spec.should_not be_nil
      spec.try(&.auth_header).should eq("Authorization")
    end

    it "has model overrides for Moonshot" do
      spec = Autobot::Providers.find_by_name("moonshot")
      spec.should_not be_nil
      overrides = spec.try(&.model_overrides) || {} of String => Hash(String, JSON::Any)
      overrides.has_key?("kimi-k2.5").should be_true
    end

    it "has strip_model_prefix for AiHubMix" do
      spec = Autobot::Providers.find_by_name("aihubmix")
      spec.should_not be_nil
      spec.try(&.strip_model_prefix?).should be_true
    end

    it "generates label from name when display_name is empty" do
      spec = Autobot::Providers::ProviderSpec.new(
        name: "test",
        keywords: ["test"],
      )
      spec.label.should eq("Test")
    end
  end
end
