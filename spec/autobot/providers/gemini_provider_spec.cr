require "../../spec_helper"

class TestableGeminiProvider < Autobot::Providers::GeminiProvider
  def test_map_messages_to_native(messages)
    map_messages_to_native(messages)
  end

  def test_parse_native_response(body : String)
    parse_native_response(body)
  end

  def test_build_code_assist_payload(
    messages,
    tools = nil,
    model = "gemini-3-flash",
    project_id = "proj-1",
    max_tokens : Int32 = 4096,
    temperature : Float64 = 0.5,
  ) : String
    build_code_assist_payload(messages, tools, model, project_id, max_tokens, temperature)
  end
end

describe Autobot::Providers::GeminiProvider do
  it "reads cached content tokens from usage metadata" do
    provider = TestableGeminiProvider.new(api_key: "test_key", model: "gemini-3.7-flash")
    body = %({"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5000,"candidatesTokenCount":10,"totalTokenCount":5010,"cachedContentTokenCount":4096}})

    usage = provider.test_parse_native_response(body).usage

    usage.prompt_tokens.should eq(5000)
    usage.cache_read_tokens.should eq(4096)
  end

  it "maps multimodal text and image blocks to native inlineData parts" do
    provider = TestableGeminiProvider.new(api_key: "test_key", model: "gemini-3.7-flash")

    messages = [
      {
        "role"    => JSON::Any.new("user"),
        "content" => JSON::Any.new([
          JSON::Any.new({
            "type" => JSON::Any.new("text"),
            "text" => JSON::Any.new("What is in this image?"),
          } of String => JSON::Any),
          JSON::Any.new({
            "type"      => JSON::Any.new("image_url"),
            "image_url" => JSON::Any.new({
              "url" => JSON::Any.new("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="),
            } of String => JSON::Any),
          } of String => JSON::Any),
        ]),
      },
    ]

    contents = provider.test_map_messages_to_native(messages)
    contents.size.should eq(1)
    user_content = contents.first
    user_content["role"].as_s.should eq("user")

    parts = user_content["parts"].as_a
    parts.size.should eq(2)
    parts[0]["text"].as_s.should eq("What is in this image?")
    parts[1]["inlineData"]["mimeType"].as_s.should eq("image/png")
    parts[1]["inlineData"]["data"].as_s.should eq("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
  end

  it "drops image blocks whose url is not a base64 data URI" do
    provider = TestableGeminiProvider.new(api_key: "test_key", model: "gemini-3.7-flash")

    messages = [
      {
        "role"    => JSON::Any.new("user"),
        "content" => JSON::Any.new([
          JSON::Any.new({
            "type" => JSON::Any.new("text"),
            "text" => JSON::Any.new("Describe this"),
          } of String => JSON::Any),
          JSON::Any.new({
            "type"      => JSON::Any.new("image_url"),
            "image_url" => JSON::Any.new({
              "url" => JSON::Any.new("https://example.com/photo.png"),
            } of String => JSON::Any),
          } of String => JSON::Any),
        ]),
      },
    ]

    parts = provider.test_map_messages_to_native(messages).first["parts"].as_a
    parts.size.should eq(1)
    parts[0]["text"].as_s.should eq("Describe this")
  end

  it "separates thought parts into reasoning_content and excludes them from content" do
    provider = TestableGeminiProvider.new(api_key: "test_key", model: "gemini-3.7-flash")
    body = <<-JSON
      {
        "candidates": [{
          "content": {
            "role": "model",
            "parts": [
              {"text": "Step 1: check prime numbers. ", "thought": true},
              {"text": "Step 2: sum them.", "thought": true},
              {"text": "The sum is "},
              {"text": "5117."}
            ]
          },
          "finishReason": "STOP"
        }]
      }
      JSON

    response = provider.test_parse_native_response(body)

    response.content.should eq("The sum is 5117.")
    response.reasoning_content.should eq("Step 1: check prime numbers. Step 2: sum them.")
    response.finish_reason.should eq("stop")
    response.native_parts.try(&.size).should eq(4)
  end

  it "ignores empty text parts such as trailing thoughtSignature placeholders" do
    provider = TestableGeminiProvider.new(api_key: "test_key", model: "gemini-3.7-flash")
    thought_only_body = <<-JSON
      {
        "candidates": [{
          "content": {
            "role": "model",
            "parts": [
              {"text": "thinking", "thought": true},
              {"text": "", "thoughtSignature": "sig_x"}
            ]
          },
          "finishReason": "STOP"
        }]
      }
      JSON

    thought_only = provider.test_parse_native_response(thought_only_body)
    thought_only.content.should be_nil
    thought_only.reasoning_content.should eq("thinking")

    answer_body = <<-JSON
      {
        "candidates": [{
          "content": {
            "role": "model",
            "parts": [
              {"text": "Answer"},
              {"text": "", "thoughtSignature": "sig_x"}
            ]
          },
          "finishReason": "STOP"
        }]
      }
      JSON

    answer = provider.test_parse_native_response(answer_body)
    answer.content.should eq("Answer")
  end

  it "maps candidate finishReason values to normalized finish_reason" do
    provider = TestableGeminiProvider.new(api_key: "test_key", model: "gemini-3.7-flash")

    {
      "STOP"                    => "stop",
      "MAX_TOKENS"              => "length",
      "SAFETY"                  => "content_filtered",
      "RECITATION"              => "content_filtered",
      "MALFORMED_FUNCTION_CALL" => "error",
      "OTHER"                   => "other",
    }.each do |raw_reason, expected|
      body = %({"candidates":[{"content":{"role":"model","parts":[{"text":"thinking","thought":true}]},"finishReason":"#{raw_reason}"}]})
      response = provider.test_parse_native_response(body)
      response.finish_reason.should eq(expected)
    end
  end

  it "preserves thought parts in tool call extra_content when only thought text precedes a function call" do
    provider = TestableGeminiProvider.new(api_key: "test_key", model: "gemini-3.7-flash")
    body = <<-JSON
      {
        "candidates": [{
          "content": {
            "role": "model",
            "parts": [
              {"text": "I need to read the config file.", "thought": true},
              {"functionCall": {"name": "read_file", "args": {"path": "config.yml"}}, "thoughtSignature": "sig_123"}
            ]
          },
          "finishReason": "STOP"
        }]
      }
      JSON

    response = provider.test_parse_native_response(body)

    response.content.should be_nil
    response.reasoning_content.should eq("I need to read the config file.")
    response.tool_calls.size.should eq(1)
    tool_call = response.tool_calls.first
    tool_call.thought_signature.should eq("sig_123")
    thought_parts = tool_call.extra_content.try(&.["thought_parts"]?.try(&.as_a?))
    thought_parts.try(&.size).should eq(1)
    thought_parts.try(&.first["thought"].as_bool).should be_true
  end

  it "omits thinkingConfig from generationConfig when thinking is not configured" do
    captured_body = Channel(JSON::Any).new(1)
    server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || "{}"
      captured_body.send(JSON.parse(body))
      ctx.response.content_type = "application/json"
      ctx.response.print(%({"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}]}))
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }

    provider = Autobot::Providers::GeminiProvider.new(
      api_key: "test_key",
      model: "gemini/gemini-3.5-flash",
      api_base: "http://127.0.0.1:#{address.port}/v1beta",
    )
    provider.chat([{"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")}], max_tokens: 2048, temperature: 0.3)

    payload = captured_body.receive
    gen_cfg = payload["generationConfig"].as_h
    gen_cfg["maxOutputTokens"].as_i.should eq(2048)
    gen_cfg["temperature"].as_f.should eq(0.3)
    gen_cfg.has_key?("thinkingConfig").should be_false
  ensure
    server.try(&.close)
  end

  it "wires providers.gemini.thinking level and budget into generateContent and Code Assist payloads" do
    captured = Channel(JSON::Any).new(2)
    server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || "{}"
      captured.send(JSON.parse(body))
      ctx.response.content_type = "application/json"
      ctx.response.print(%({"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}]}))
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }

    level_config = Autobot::Config::Config.from_yaml(<<-YAML
    agents:
      defaults:
        model: "gemini/gemini-3.5-flash"
    providers:
      gemini:
        api_key: "test_key"
        api_base: "http://127.0.0.1:#{address.port}/v1beta"
        thinking:
          level: "low"
    YAML
    )
    level_provider = Autobot::CLI::SetupHelper.create_provider(level_config)
    level_provider.chat([{"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")}])
    level_payload = captured.receive
    level_payload["generationConfig"]["thinkingConfig"]["thinkingLevel"].as_s.should eq("LOW")

    budget_config = Autobot::Config::Config.from_yaml(<<-YAML
    agents:
      defaults:
        model: "gemini/gemini-2.5-flash"
    providers:
      gemini:
        api_key: "test_key"
        api_base: "http://127.0.0.1:#{address.port}/v1beta"
        thinking:
          budget: 0
    YAML
    )
    budget_provider = Autobot::CLI::SetupHelper.create_provider(budget_config)
    budget_provider.chat([{"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")}])
    budget_payload = captured.receive
    budget_payload["generationConfig"]["thinkingConfig"]["thinkingBudget"].as_i.should eq(0)

    oauth_provider = TestableGeminiProvider.new(
      api_key: "",
      model: "gemini/gemini-3.5-flash",
      thinking_level: "high",
    )
    oauth_json = JSON.parse(
      oauth_provider.test_build_code_assist_payload(
        [{"role" => JSON::Any.new("user"), "content" => JSON::Any.new("hi")}],
        max_tokens: 4096,
        temperature: 0.4,
      )
    )
    oauth_gen_cfg = oauth_json["request"]["generationConfig"]
    oauth_gen_cfg["maxOutputTokens"].as_i.should eq(4096)
    oauth_gen_cfg["temperature"].as_f.should eq(0.4)
    oauth_gen_cfg["thinkingConfig"]["thinkingLevel"].as_s.should eq("HIGH")
  ensure
    server.try(&.close)
  end
end
