require "json"

module Autobot::Providers
  # Converts OpenAI-style tool definitions to Bedrock Converse `toolConfig` format.
  #
  # OpenAI format:
  #   {"type": "function", "function": {"name": "x", "description": "y", "parameters": {...}}}
  #
  # Bedrock format:
  #   {"toolSpec": {"name": "x", "description": "y", "inputSchema": {"json": {...}}}}
  module ToolConverter
    # Builds the full `toolConfig` object for the Bedrock request body.
    # Returns nil if tools list is empty.
    def self.build_tool_config(tools : Array(Hash(String, JSON::Any))?) : JSON::Any?
      return nil if tools.nil? || tools.empty?

      tool_specs = tools.compact_map { |tool| convert_tool(tool) }
      return nil if tool_specs.empty?

      JSON::Any.new({
        "tools"      => JSON::Any.new(tool_specs),
        "toolChoice" => JSON::Any.new({"auto" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any),
      } of String => JSON::Any)
    end

    private def self.convert_tool(tool : Hash(String, JSON::Any)) : JSON::Any?
      func = tool["function"]?
      return nil unless func

      name = func["name"]?.try(&.as_s?) || ""
      description = func["description"]?.try(&.as_s?) || ""
      parameters = func["parameters"]? || JSON::Any.new({} of String => JSON::Any)

      tool_spec = JSON::Any.new({
        "name"        => JSON::Any.new(name),
        "description" => JSON::Any.new(description),
        "inputSchema" => JSON::Any.new({"json" => parameters} of String => JSON::Any),
      } of String => JSON::Any)

      JSON::Any.new({"toolSpec" => tool_spec} of String => JSON::Any)
    end
  end
end
