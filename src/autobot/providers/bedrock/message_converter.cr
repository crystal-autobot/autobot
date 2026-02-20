require "json"

module Autobot::Providers
  # Converts Autobot internal message format to Bedrock Converse API format.
  #
  # Key differences from OpenAI/Anthropic:
  # - System messages → separate `system` array param
  # - Content is array of union-key blocks (`{"text": "..."}` not `{"type": "text", "text": "..."}`)
  # - Tool results are sent as user messages with `toolResult` blocks
  # - Tool calls use `toolUse` blocks with camelCase keys
  module MessageConverter
    # Extracts system messages and returns them as Bedrock system content blocks.
    def self.extract_system(messages : Array(Hash(String, JSON::Any))) : Array(JSON::Any)
      messages
        .select { |msg| msg["role"]?.try(&.as_s?) == "system" }
        .compact_map { |msg| msg["content"]?.try(&.as_s?) }
        .reject(&.empty?)
        .map { |text| JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any) }
    end

    # Converts non-system messages to Bedrock Converse format.
    # Merges consecutive same-role messages to avoid API rejection.
    def self.convert(messages : Array(Hash(String, JSON::Any))) : Array(JSON::Any)
      converted = messages
        .reject { |msg| msg["role"]?.try(&.as_s?) == "system" }
        .map { |msg| convert_message(msg) }

      merge_consecutive(converted)
    end

    private def self.convert_message(message : Hash(String, JSON::Any)) : JSON::Any
      role = message["role"]?.try(&.as_s?) || "user"

      case role
      when "tool"
        convert_tool_result(message)
      when "assistant"
        message["tool_calls"]? ? convert_assistant_with_tools(message) : convert_text_message("assistant", message)
      else
        convert_text_message("user", message)
      end
    end

    private def self.convert_text_message(role : String, message : Hash(String, JSON::Any)) : JSON::Any
      text = message["content"]?.try(&.as_s?) || ""
      content = [JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)] of JSON::Any

      JSON::Any.new({
        "role"    => JSON::Any.new(role),
        "content" => JSON::Any.new(content),
      } of String => JSON::Any)
    end

    private def self.convert_tool_result(message : Hash(String, JSON::Any)) : JSON::Any
      tool_call_id = message["tool_call_id"]?.try(&.as_s?) || ""
      content_text = message["content"]?.try(&.as_s?) || ""

      tool_result = JSON::Any.new({
        "toolUseId" => JSON::Any.new(tool_call_id),
        "content"   => JSON::Any.new([
          JSON::Any.new({"text" => JSON::Any.new(content_text)} of String => JSON::Any),
        ] of JSON::Any),
      } of String => JSON::Any)

      JSON::Any.new({
        "role"    => JSON::Any.new("user"),
        "content" => JSON::Any.new([
          JSON::Any.new({"toolResult" => tool_result} of String => JSON::Any),
        ] of JSON::Any),
      } of String => JSON::Any)
    end

    private def self.convert_assistant_with_tools(message : Hash(String, JSON::Any)) : JSON::Any
      content_blocks = [] of JSON::Any

      if text = message["content"]?.try(&.as_s?)
        unless text.empty?
          content_blocks << JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)
        end
      end

      if tool_calls = message["tool_calls"]?.try(&.as_a?)
        tool_calls.each do |tool_call|
          block = convert_tool_call_to_tool_use(tool_call)
          content_blocks << block if block
        end
      end

      JSON::Any.new({
        "role"    => JSON::Any.new("assistant"),
        "content" => JSON::Any.new(content_blocks),
      } of String => JSON::Any)
    end

    private def self.convert_tool_call_to_tool_use(tool_call : JSON::Any) : JSON::Any?
      func = tool_call["function"]?
      return nil unless func

      id = tool_call["id"]?.try(&.as_s?) || ""
      name = func["name"]?.try(&.as_s?) || ""
      input = parse_tool_input(func["arguments"]?)

      tool_use = JSON::Any.new({
        "toolUseId" => JSON::Any.new(id),
        "name"      => JSON::Any.new(name),
        "input"     => input,
      } of String => JSON::Any)

      JSON::Any.new({"toolUse" => tool_use} of String => JSON::Any)
    end

    private def self.parse_tool_input(args : JSON::Any?) : JSON::Any
      return JSON::Any.new({} of String => JSON::Any) unless args

      if str = args.as_s?
        begin
          JSON.parse(str)
        rescue
          JSON::Any.new({} of String => JSON::Any)
        end
      else
        args
      end
    end

    # Merges consecutive messages with the same role by combining their content blocks.
    private def self.merge_consecutive(messages : Array(JSON::Any)) : Array(JSON::Any)
      return messages if messages.size <= 1

      result = [messages.first]

      messages.skip(1).each do |msg|
        last = result.last
        if same_role?(last, msg)
          result[-1] = merge_messages(last, msg)
        else
          result << msg
        end
      end

      result
    end

    private def self.same_role?(a : JSON::Any, b : JSON::Any) : Bool
      a["role"]?.try(&.as_s?) == b["role"]?.try(&.as_s?)
    end

    private def self.merge_messages(a : JSON::Any, b : JSON::Any) : JSON::Any
      content_a = a["content"]?.try(&.as_a?) || [] of JSON::Any
      content_b = b["content"]?.try(&.as_a?) || [] of JSON::Any

      JSON::Any.new({
        "role"    => a["role"]? || JSON::Any.new("user"),
        "content" => JSON::Any.new(content_a + content_b),
      } of String => JSON::Any)
    end
  end
end
