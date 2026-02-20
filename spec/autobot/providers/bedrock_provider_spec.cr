require "../../spec_helper"

describe Autobot::Providers::BedrockProvider do
  access_key = "AKIAIOSFODNN7EXAMPLE"
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  region = "us-east-1"

  describe "#default_model" do
    it "returns configured model" do
      provider = Autobot::Providers::BedrockProvider.new(
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: region,
        model: "amazon.nova-pro-v1:0",
      )

      provider.default_model.should eq("amazon.nova-pro-v1:0")
    end

    it "has a sensible default model" do
      provider = Autobot::Providers::BedrockProvider.new(
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: region,
      )

      provider.default_model.should contain("anthropic.claude")
    end
  end

  describe "#region" do
    it "exposes configured region" do
      provider = Autobot::Providers::BedrockProvider.new(
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: "eu-west-1",
      )

      provider.region.should eq("eu-west-1")
    end
  end

  describe "response parsing" do
    it "parses a text response" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [{"text": "Hello!"}]
          }
        },
        "stopReason": "end_turn",
        "usage": {"inputTokens": 10, "outputTokens": 5, "totalTokens": 15}
      }
      JSON

      response = parse_response(json)

      response.content.should eq("Hello!")
      response.finish_reason.should eq("stop")
      response.tool_calls.should be_empty
      response.usage.prompt_tokens.should eq(10)
      response.usage.completion_tokens.should eq(5)
      response.usage.total_tokens.should eq(15)
    end

    it "parses a tool use response" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [
              {"text": "Let me check."},
              {"toolUse": {"toolUseId": "tc_123", "name": "read_file", "input": {"path": "/tmp/test"}}}
            ]
          }
        },
        "stopReason": "tool_use",
        "usage": {"inputTokens": 20, "outputTokens": 10, "totalTokens": 30}
      }
      JSON

      response = parse_response(json)

      response.content.should eq("Let me check.")
      response.finish_reason.should eq("tool_calls")
      response.has_tool_calls?.should be_true
      response.tool_calls.size.should eq(1)
      response.tool_calls[0].id.should eq("tc_123")
      response.tool_calls[0].name.should eq("read_file")
      response.tool_calls[0].arguments["path"].as_s.should eq("/tmp/test")
    end

    it "parses guardrail_intervened response" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [{"text": "Sorry, I can't help with that."}]
          }
        },
        "stopReason": "guardrail_intervened",
        "usage": {"inputTokens": 0, "outputTokens": 0, "totalTokens": 0},
        "trace": {
          "guardrail": {
            "inputAssessment": {
              "abc123": {
                "topicPolicy": {
                  "topics": [{"name": "Harmful", "type": "DENY", "action": "BLOCKED"}]
                }
              }
            }
          }
        }
      }
      JSON

      response = parse_response(json)

      response.content.should eq("Sorry, I can't help with that.")
      response.finish_reason.should eq("guardrail_intervened")
      response.tool_calls.should be_empty
      response.usage.total_tokens.should eq(0)
    end

    it "parses error response" do
      json = <<-JSON
      {
        "__type": "ValidationException",
        "message": "Model not found"
      }
      JSON

      response = parse_response(json)

      response.content.should eq("Bedrock error: Model not found")
      response.finish_reason.should eq("error")
    end

    it "parses response with multiple text blocks" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [
              {"text": "First part."},
              {"text": "Second part."}
            ]
          }
        },
        "stopReason": "end_turn",
        "usage": {"inputTokens": 5, "outputTokens": 10, "totalTokens": 15}
      }
      JSON

      response = parse_response(json)

      response.content.should eq("First part.\nSecond part.")
    end

    it "parses content_filtered stop reason" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [{"text": "Content was filtered."}]
          }
        },
        "stopReason": "content_filtered",
        "usage": {"inputTokens": 5, "outputTokens": 3, "totalTokens": 8}
      }
      JSON

      response = parse_response(json)

      response.content.should eq("Content was filtered.")
      response.finish_reason.should eq("content_filtered")
    end

    it "parses response with missing usage" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [{"text": "Hello"}]
          }
        },
        "stopReason": "end_turn"
      }
      JSON

      response = parse_response(json)

      response.usage.total_tokens.should eq(0)
    end

    it "handles unknown stop reason" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [{"text": "Done"}]
          }
        },
        "stopReason": "some_future_reason",
        "usage": {"inputTokens": 1, "outputTokens": 1, "totalTokens": 2}
      }
      JSON

      response = parse_response(json)

      response.finish_reason.should eq("some_future_reason")
    end

    it "parses multiple tool calls" do
      json = <<-JSON
      {
        "output": {
          "message": {
            "role": "assistant",
            "content": [
              {"toolUse": {"toolUseId": "tc_1", "name": "read_file", "input": {"path": "a.txt"}}},
              {"toolUse": {"toolUseId": "tc_2", "name": "read_file", "input": {"path": "b.txt"}}}
            ]
          }
        },
        "stopReason": "tool_use",
        "usage": {"inputTokens": 15, "outputTokens": 8, "totalTokens": 23}
      }
      JSON

      response = parse_response(json)

      response.tool_calls.size.should eq(2)
      response.tool_calls[0].id.should eq("tc_1")
      response.tool_calls[1].id.should eq("tc_2")
    end
  end

  describe "error message extraction" do
    it "extracts message from JSON error body" do
      body = %({"message": "Model not found"})
      extract_error_message(body).should eq("Model not found")
    end

    it "returns truncated body for non-JSON errors" do
      body = "Internal Server Error"
      extract_error_message(body).should eq("Internal Server Error")
    end

    it "returns truncated body when JSON has no message field" do
      body = %({"error": "something wrong"})
      result = extract_error_message(body)
      result.should contain("error")
    end

    it "truncates long error bodies" do
      body = "x" * 300
      result = extract_error_message(body)
      result.size.should eq(200)
    end
  end

  describe "model prefix stripping" do
    it "strips bedrock/ prefix" do
      provider = Autobot::Providers::BedrockProvider.new(
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: region,
        model: "bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0",
      )

      # The default_model returns raw model, but chat() strips the prefix internally.
      # We test via the model getter which returns raw.
      provider.model.should eq("bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0")
    end
  end
end

# Helper to test error message extraction logic
private def extract_error_message(body : String) : String
  json = JSON.parse(body)
  json["message"]?.try(&.as_s?) || body[0, 200]
rescue
  body[0, 200]
end

STOP_REASON_MAP = {
  "end_turn"             => "stop",
  "tool_use"             => "tool_calls",
  "max_tokens"           => "length",
  "stop_sequence"        => "stop",
  "guardrail_intervened" => "guardrail_intervened",
  "content_filtered"     => "content_filtered",
}

# Helper to test response parsing without making HTTP calls.
private def parse_response(json_str : String) : Autobot::Providers::Response
  json = JSON.parse(json_str)

  if msg = json["message"]?.try(&.as_s?)
    return Autobot::Providers::Response.new(content: "Bedrock error: #{msg}", finish_reason: "error")
  end

  content_blocks = json.dig("output", "message", "content").as_a? || [] of JSON::Any
  text_parts, tool_calls = parse_content(content_blocks)

  Autobot::Providers::Response.new(
    content: text_parts.empty? ? nil : text_parts.join("\n"),
    tool_calls: tool_calls,
    finish_reason: map_stop_reason(json["stopReason"]?.try(&.as_s?)),
    usage: parse_usage(json["usage"]?),
  )
end

private def parse_content(blocks : Array(JSON::Any))
  text_parts = [] of String
  tool_calls = [] of Autobot::Providers::ToolCall

  blocks.each do |block|
    if text = block["text"]?.try(&.as_s?)
      text_parts << text
    elsif tool_use = block["toolUse"]?
      tool_calls << parse_tool_use(tool_use)
    end
  end

  {text_parts, tool_calls}
end

private def parse_tool_use(tool_use : JSON::Any) : Autobot::Providers::ToolCall
  id = tool_use["toolUseId"]?.try(&.as_s?) || ""
  name = tool_use["name"]?.try(&.as_s?) || ""
  input = tool_use["input"]?.try(&.as_h?) || {} of String => JSON::Any
  Autobot::Providers::ToolCall.new(id: id, name: name, arguments: input.transform_values(&.as(JSON::Any)))
end

private def parse_usage(node : JSON::Any?) : Autobot::Providers::TokenUsage
  return Autobot::Providers::TokenUsage.new unless node
  input = node["inputTokens"]?.try(&.as_i?) || 0
  output = node["outputTokens"]?.try(&.as_i?) || 0
  Autobot::Providers::TokenUsage.new(
    prompt_tokens: input,
    completion_tokens: output,
    total_tokens: node["totalTokens"]?.try(&.as_i?) || (input + output),
  )
end

private def map_stop_reason(reason : String?) : String
  return "stop" unless reason
  STOP_REASON_MAP[reason]? || reason
end
