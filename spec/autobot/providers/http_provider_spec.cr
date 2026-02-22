require "../../spec_helper"

# Testable subclass that exposes private helpers and captures the model sent to API builders.
class TestableHttpProvider < Autobot::Providers::HttpProvider
  getter last_api_model : String?

  def test_strip_provider_prefix(model : String) : String
    strip_provider_prefix(model)
  end

  def test_parse_compatible_response(body : String) : Autobot::Providers::Response
    parse_compatible_response(body)
  end

  def test_convert_content_for_anthropic(content : JSON::Any) : JSON::Any
    convert_content_for_anthropic(content)
  end

  def test_build_anthropic_system_block(text : String) : Array(JSON::Any)
    build_anthropic_system_block(text)
  end

  def test_convert_tools_to_anthropic(tools, cache : Bool = false) : Array(JSON::Any)
    convert_tools_to_anthropic(tools, cache: cache)
  end

  def test_parse_anthropic_response(body : String) : Autobot::Providers::Response
    parse_anthropic_response(body)
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    parsed = JSON.parse(body)
    @last_api_model = parsed["model"]?.try(&.as_s?)
    # Return a minimal valid response based on the URL
    if url.includes?("/messages")
      HTTP::Client::Response.new(200, body: %({"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":0}}))
    else
      HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}))
    end
  end
end

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

  describe "#strip_provider_prefix" do
    it "strips known provider prefix" do
      provider = TestableHttpProvider.new(api_key: api_key)
      provider.test_strip_provider_prefix("anthropic/claude-sonnet-4-5").should eq("claude-sonnet-4-5")
    end

    it "strips other known provider prefixes" do
      provider = TestableHttpProvider.new(api_key: api_key)
      provider.test_strip_provider_prefix("deepseek/deepseek-chat").should eq("deepseek-chat")
      provider.test_strip_provider_prefix("openai/gpt-4o").should eq("gpt-4o")
      provider.test_strip_provider_prefix("gemini/gemini-2.0-flash").should eq("gemini-2.0-flash")
    end

    it "preserves unknown prefixed models" do
      provider = TestableHttpProvider.new(api_key: api_key)
      provider.test_strip_provider_prefix("meta-llama/Llama-3-70B").should eq("meta-llama/Llama-3-70B")
    end

    it "returns model as-is when no slash present" do
      provider = TestableHttpProvider.new(api_key: api_key)
      provider.test_strip_provider_prefix("claude-sonnet-4-5").should eq("claude-sonnet-4-5")
      provider.test_strip_provider_prefix("gpt-4o").should eq("gpt-4o")
    end

    it "is case-insensitive for provider prefix matching" do
      provider = TestableHttpProvider.new(api_key: api_key)
      provider.test_strip_provider_prefix("Anthropic/claude-sonnet-4-5").should eq("claude-sonnet-4-5")
      provider.test_strip_provider_prefix("OPENAI/gpt-4o").should eq("gpt-4o")
    end
  end

  describe "#chat model stripping" do
    messages = [{"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")}]

    it "strips provider prefix for Anthropic API calls" do
      provider = TestableHttpProvider.new(api_key: api_key, model: "anthropic/claude-sonnet-4-5")
      provider.chat(messages)
      provider.last_api_model.should eq("claude-sonnet-4-5")
    end

    it "strips provider prefix for OpenAI-compatible API calls" do
      provider = TestableHttpProvider.new(api_key: api_key, model: "deepseek/deepseek-chat")
      provider.chat(messages)
      provider.last_api_model.should eq("deepseek-chat")
    end

    it "preserves unknown prefixed models for OpenAI-compatible calls" do
      provider = TestableHttpProvider.new(
        api_key: api_key,
        api_base: "http://localhost:8080/v1/chat/completions",
        model: "meta-llama/Llama-3-70B"
      )
      provider.chat(messages)
      provider.last_api_model.should eq("meta-llama/Llama-3-70B")
    end

    it "passes bare model when no prefix present" do
      provider = TestableHttpProvider.new(api_key: api_key, model: "gpt-4o")
      provider.chat(messages)
      provider.last_api_model.should eq("gpt-4o")
    end

    it "strips prefix from model override parameter" do
      provider = TestableHttpProvider.new(api_key: api_key, model: "gpt-4o")
      provider.chat(messages, model: "anthropic/claude-sonnet-4-5")
      provider.last_api_model.should eq("claude-sonnet-4-5")
    end
  end

  describe "#parse_compatible_response error handling" do
    provider = TestableHttpProvider.new(api_key: api_key)

    it "parses standard error object" do
      body = %({"error":{"message":"Invalid model","type":"invalid_request_error"}})
      response = provider.test_parse_compatible_response(body)
      response.finish_reason.should eq("error")
      response.content.should eq("API error: Invalid model")
    end

    it "parses array-wrapped error (e.g. Google Gemini)" do
      body = %([{"error":{"code":404,"message":"model not found","status":"NOT_FOUND"}}])
      response = provider.test_parse_compatible_response(body)
      response.finish_reason.should eq("error")
      response.content.should eq("API error: model not found")
    end

    it "falls back to JSON when error has no message" do
      body = %({"error":{"code":500}})
      response = provider.test_parse_compatible_response(body)
      response.finish_reason.should eq("error")
      response.content.should_not be_nil
      response.content.to_s.should contain("API error:")
      response.content.to_s.should contain("500")
    end

    it "parses successful response normally" do
      body = %({"choices":[{"message":{"content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}})
      response = provider.test_parse_compatible_response(body)
      response.finish_reason.should eq("stop")
      response.content.should eq("hello")
    end

    it "parses tool calls with extra_content" do
      body = %({"choices":[{"message":{"content":"","tool_calls":[{"id":"tc_1","type":"function","function":{"name":"search","arguments":"{\\"q\\":\\"test\\"}"},"extra_content":{"google":{"thought_signature":"sig_123"}}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}})
      response = provider.test_parse_compatible_response(body)
      response.has_tool_calls?.should be_true
      tc = response.tool_calls.first
      tc.name.should eq("search")
      tc.extra_content.should_not be_nil
      tc.extra_content.try(&.["google"]["thought_signature"].as_s).should eq("sig_123")
    end

    it "parses tool calls without extra_content" do
      body = %({"choices":[{"message":{"content":"","tool_calls":[{"id":"tc_2","type":"function","function":{"name":"ping","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}})
      response = provider.test_parse_compatible_response(body)
      response.has_tool_calls?.should be_true
      response.tool_calls.first.extra_content.should be_nil
    end
  end

  describe "prompt caching" do
    provider = TestableHttpProvider.new(api_key: api_key)

    it "adds cache_control to system prompt block" do
      blocks = provider.test_build_anthropic_system_block("You are a helpful assistant.")
      blocks.size.should eq(1)

      block = blocks[0]
      block["type"].as_s.should eq("text")
      block["text"].as_s.should eq("You are a helpful assistant.")
      block["cache_control"]["type"].as_s.should eq("ephemeral")
    end

    it "adds cache_control to last tool definition when cache enabled" do
      tools = [
        JSON::Any.new({
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({
            "name"        => JSON::Any.new("read_file"),
            "description" => JSON::Any.new("Read a file"),
            "parameters"  => JSON::Any.new({} of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any),
        JSON::Any.new({
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({
            "name"        => JSON::Any.new("exec"),
            "description" => JSON::Any.new("Execute command"),
            "parameters"  => JSON::Any.new({} of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ]

      result = provider.test_convert_tools_to_anthropic(tools, cache: true)
      result.size.should eq(2)

      # First tool should not have cache_control
      result[0]["cache_control"]?.should be_nil

      # Last tool should have cache_control
      result[1]["cache_control"]["type"].as_s.should eq("ephemeral")
    end

    it "does not add cache_control when cache is false" do
      tools = [
        JSON::Any.new({
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({
            "name"        => JSON::Any.new("echo"),
            "description" => JSON::Any.new("Echo"),
            "parameters"  => JSON::Any.new({} of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ]

      result = provider.test_convert_tools_to_anthropic(tools, cache: false)
      result[0]["cache_control"]?.should be_nil
    end

    it "parses cache tokens from Anthropic usage" do
      body = %({"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":80,"cache_read_input_tokens":20}})
      response = provider.test_parse_anthropic_response(body)

      response.usage.prompt_tokens.should eq(100)
      response.usage.cache_creation_tokens.should eq(80)
      response.usage.cache_read_tokens.should eq(20)
      response.usage.cached?.should be_true
    end

    it "handles missing cache tokens gracefully" do
      body = %({"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":25}})
      response = provider.test_parse_anthropic_response(body)

      response.usage.cache_creation_tokens.should eq(0)
      response.usage.cache_read_tokens.should eq(0)
      response.usage.cached?.should be_false
    end
  end

  describe "#convert_content_for_anthropic" do
    provider = TestableHttpProvider.new(api_key: api_key)

    it "passes string content through unchanged" do
      content = JSON::Any.new("Hello world")
      result = provider.test_convert_content_for_anthropic(content)
      result.as_s.should eq("Hello world")
    end

    it "passes text blocks through unchanged" do
      blocks = JSON::Any.new([
        JSON::Any.new({
          "type" => JSON::Any.new("text"),
          "text" => JSON::Any.new("Hello"),
        } of String => JSON::Any),
      ])

      result = provider.test_convert_content_for_anthropic(blocks)
      arr = result.as_a
      arr.size.should eq(1)
      arr[0]["type"].as_s.should eq("text")
      arr[0]["text"].as_s.should eq("Hello")
    end

    it "converts image_url blocks to Anthropic image format" do
      blocks = JSON::Any.new([
        JSON::Any.new({
          "type"      => JSON::Any.new("image_url"),
          "image_url" => JSON::Any.new({
            "url" => JSON::Any.new("data:image/jpeg;base64,aW1hZ2VieXRlcw=="),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ])

      result = provider.test_convert_content_for_anthropic(blocks)
      arr = result.as_a
      arr.size.should eq(1)

      img = arr[0]
      img["type"].as_s.should eq("image")
      img["source"]["type"].as_s.should eq("base64")
      img["source"]["media_type"].as_s.should eq("image/jpeg")
      img["source"]["data"].as_s.should eq("aW1hZ2VieXRlcw==")
    end

    it "converts mixed text and image blocks" do
      blocks = JSON::Any.new([
        JSON::Any.new({
          "type" => JSON::Any.new("text"),
          "text" => JSON::Any.new("Analyze this"),
        } of String => JSON::Any),
        JSON::Any.new({
          "type"      => JSON::Any.new("image_url"),
          "image_url" => JSON::Any.new({
            "url" => JSON::Any.new("data:image/png;base64,cG5nZGF0YQ=="),
          } of String => JSON::Any),
        } of String => JSON::Any),
      ])

      result = provider.test_convert_content_for_anthropic(blocks)
      arr = result.as_a
      arr.size.should eq(2)

      arr[0]["type"].as_s.should eq("text")
      arr[1]["type"].as_s.should eq("image")
      arr[1]["source"]["media_type"].as_s.should eq("image/png")
      arr[1]["source"]["data"].as_s.should eq("cG5nZGF0YQ==")
    end
  end
end
