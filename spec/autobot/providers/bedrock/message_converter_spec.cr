require "../../../spec_helper"

describe Autobot::Providers::MessageConverter do
  describe ".extract_system" do
    it "extracts system messages as text blocks" do
      messages = [
        {"role" => json_s("system"), "content" => json_s("You are helpful.")},
        {"role" => json_s("user"), "content" => json_s("Hello")},
      ]

      result = Autobot::Providers::MessageConverter.extract_system(messages)

      result.size.should eq(1)
      result[0]["text"].as_s.should eq("You are helpful.")
    end

    it "returns empty array when no system messages" do
      messages = [
        {"role" => json_s("user"), "content" => json_s("Hello")},
      ]

      result = Autobot::Providers::MessageConverter.extract_system(messages)
      result.should be_empty
    end

    it "concatenates multiple system messages" do
      messages = [
        {"role" => json_s("system"), "content" => json_s("Rule 1")},
        {"role" => json_s("system"), "content" => json_s("Rule 2")},
        {"role" => json_s("user"), "content" => json_s("Hello")},
      ]

      result = Autobot::Providers::MessageConverter.extract_system(messages)

      result.size.should eq(2)
      result[0]["text"].as_s.should eq("Rule 1")
      result[1]["text"].as_s.should eq("Rule 2")
    end

    it "skips empty system messages" do
      messages = [
        {"role" => json_s("system"), "content" => json_s("")},
        {"role" => json_s("user"), "content" => json_s("Hello")},
      ]

      result = Autobot::Providers::MessageConverter.extract_system(messages)
      result.should be_empty
    end
  end

  describe ".convert" do
    it "converts user message to text content block" do
      messages = [
        {"role" => json_s("user"), "content" => json_s("Hello")},
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(1)
      result[0]["role"].as_s.should eq("user")
      result[0]["content"][0]["text"].as_s.should eq("Hello")
    end

    it "converts assistant message to text content block" do
      messages = [
        {"role" => json_s("assistant"), "content" => json_s("Hi there")},
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(1)
      result[0]["role"].as_s.should eq("assistant")
      result[0]["content"][0]["text"].as_s.should eq("Hi there")
    end

    it "excludes system messages" do
      messages = [
        {"role" => json_s("system"), "content" => json_s("System prompt")},
        {"role" => json_s("user"), "content" => json_s("Hello")},
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(1)
      result[0]["role"].as_s.should eq("user")
    end

    it "converts tool result to user message with toolResult block" do
      messages = [
        {"role" => json_s("tool"), "tool_call_id" => json_s("tc_123"), "content" => json_s("result data")},
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(1)
      result[0]["role"].as_s.should eq("user")
      tool_result = result[0]["content"][0]["toolResult"]
      tool_result["toolUseId"].as_s.should eq("tc_123")
      tool_result["content"][0]["text"].as_s.should eq("result data")
    end

    it "converts assistant message with tool calls to toolUse blocks" do
      tool_call = JSON::Any.new({
        "id"       => JSON::Any.new("tc_456"),
        "function" => JSON::Any.new({
          "name"      => JSON::Any.new("read_file"),
          "arguments" => JSON::Any.new(%({"path": "/tmp/test"})),
        } of String => JSON::Any),
      } of String => JSON::Any)

      messages = [
        {
          "role"       => json_s("assistant"),
          "content"    => json_s("Let me check that."),
          "tool_calls" => JSON::Any.new([tool_call] of JSON::Any),
        },
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(1)
      result[0]["role"].as_s.should eq("assistant")
      content = result[0]["content"].as_a
      content.size.should eq(2)
      content[0]["text"].as_s.should eq("Let me check that.")
      content[1]["toolUse"]["toolUseId"].as_s.should eq("tc_456")
      content[1]["toolUse"]["name"].as_s.should eq("read_file")
    end

    it "merges consecutive user messages" do
      messages = [
        {"role" => json_s("user"), "content" => json_s("Part 1")},
        {"role" => json_s("user"), "content" => json_s("Part 2")},
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(1)
      result[0]["role"].as_s.should eq("user")
      result[0]["content"].as_a.size.should eq(2)
    end

    it "merges consecutive tool results into single user message" do
      messages = [
        {"role" => json_s("tool"), "tool_call_id" => json_s("tc_1"), "content" => json_s("result 1")},
        {"role" => json_s("tool"), "tool_call_id" => json_s("tc_2"), "content" => json_s("result 2")},
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(1)
      result[0]["role"].as_s.should eq("user")
      content = result[0]["content"].as_a
      content.size.should eq(2)
    end

    it "does not merge messages with different roles" do
      messages = [
        {"role" => json_s("user"), "content" => json_s("Hello")},
        {"role" => json_s("assistant"), "content" => json_s("Hi")},
        {"role" => json_s("user"), "content" => json_s("How are you?")},
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)

      result.size.should eq(3)
    end

    it "skips empty text in assistant tool messages" do
      tool_call = JSON::Any.new({
        "id"       => JSON::Any.new("tc_1"),
        "function" => JSON::Any.new({
          "name"      => JSON::Any.new("test"),
          "arguments" => JSON::Any.new("{}"),
        } of String => JSON::Any),
      } of String => JSON::Any)

      messages = [
        {
          "role"       => json_s("assistant"),
          "content"    => json_s(""),
          "tool_calls" => JSON::Any.new([tool_call] of JSON::Any),
        },
      ]

      result = Autobot::Providers::MessageConverter.convert(messages)
      content = result[0]["content"].as_a

      # Only toolUse block, no empty text block
      content.size.should eq(1)
      content[0]["toolUse"]?.should_not be_nil
    end
  end
end

private def json_s(value : String) : JSON::Any
  JSON::Any.new(value)
end
