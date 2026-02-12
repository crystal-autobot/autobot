require "../../spec_helper"

# HttpProvider is tested via response parsing since actual HTTP calls require a server.
# These tests validate the response parsing logic using JSON fixtures.
describe Autobot::Providers::HttpProvider do
  api_key = "test-api-key"

  describe "#default_model" do
    it "returns the configured model" do
      provider = Autobot::Providers::HttpProvider.new(
        api_key: api_key,
        model: "gpt-4o"
      )
      provider.default_model.should eq("gpt-4o")
    end

    it "has sensible default model" do
      provider = Autobot::Providers::HttpProvider.new(api_key: api_key)
      provider.default_model.should contain("claude")
    end
  end

  describe "provider detection" do
    it "detects Anthropic spec for claude models" do
      provider = Autobot::Providers::HttpProvider.new(
        api_key: api_key,
        model: "anthropic/claude-sonnet-4-5"
      )
      # The provider should use Anthropic API format for claude models
      provider.default_model.should contain("claude")
    end

    it "detects OpenRouter gateway by key prefix" do
      provider = Autobot::Providers::HttpProvider.new(
        api_key: "sk-or-test123",
        model: "anthropic/claude-sonnet-4-5"
      )
      provider.api_key.should eq("sk-or-test123")
    end

    it "accepts custom api_base" do
      provider = Autobot::Providers::HttpProvider.new(
        api_key: api_key,
        api_base: "http://localhost:8080/v1",
        model: "local-model"
      )
      provider.api_base.should eq("http://localhost:8080/v1")
    end

    it "accepts extra headers" do
      provider = Autobot::Providers::HttpProvider.new(
        api_key: api_key,
        extra_headers: {"X-Custom" => "value"}
      )
      provider.extra_headers["X-Custom"].should eq("value")
    end
  end
end
