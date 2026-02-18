require "../../../spec_helper"

describe Autobot::Providers::ToolConverter do
  describe ".build_tool_config" do
    it "returns nil for nil tools" do
      Autobot::Providers::ToolConverter.build_tool_config(nil).should be_nil
    end

    it "returns nil for empty tools array" do
      Autobot::Providers::ToolConverter.build_tool_config([] of Hash(String, JSON::Any)).should be_nil
    end

    it "converts a single tool to toolSpec format" do
      tools = [build_tool("read_file", "Read a file", {"path" => "string"})]

      result = Autobot::Providers::ToolConverter.build_tool_config(tools)

      result.should_not be_nil
      config = result.as(JSON::Any)
      tool_specs = config["tools"].as_a
      tool_specs.size.should eq(1)

      spec = tool_specs[0]["toolSpec"]
      spec["name"].as_s.should eq("read_file")
      spec["description"].as_s.should eq("Read a file")
      spec["inputSchema"]["json"].should_not be_nil
    end

    it "sets toolChoice to auto" do
      tools = [build_tool("test", "Test tool", {} of String => String)]

      result = Autobot::Providers::ToolConverter.build_tool_config(tools)

      config = result.as(JSON::Any)
      config["toolChoice"]["auto"].should_not be_nil
    end

    it "converts multiple tools" do
      tools = [
        build_tool("read_file", "Read a file", {"path" => "string"}),
        build_tool("write_file", "Write a file", {"path" => "string", "content" => "string"}),
      ]

      result = Autobot::Providers::ToolConverter.build_tool_config(tools)

      config = result.as(JSON::Any)
      config["tools"].as_a.size.should eq(2)
    end

    it "preserves parameters as inputSchema json" do
      params = {
        "type"       => JSON::Any.new("object"),
        "properties" => JSON::Any.new({
          "path" => JSON::Any.new({
            "type"        => JSON::Any.new("string"),
            "description" => JSON::Any.new("File path"),
          } of String => JSON::Any),
        } of String => JSON::Any),
        "required" => JSON::Any.new([JSON::Any.new("path")] of JSON::Any),
      } of String => JSON::Any

      tools = [{
        "type"     => JSON::Any.new("function"),
        "function" => JSON::Any.new({
          "name"        => JSON::Any.new("read_file"),
          "description" => JSON::Any.new("Read a file"),
          "parameters"  => JSON::Any.new(params),
        } of String => JSON::Any),
      } of String => JSON::Any]

      result = Autobot::Providers::ToolConverter.build_tool_config(tools)

      config = result.as(JSON::Any)
      input_schema = config["tools"][0]["toolSpec"]["inputSchema"]["json"]
      input_schema["type"].as_s.should eq("object")
      input_schema["properties"]["path"]["type"].as_s.should eq("string")
    end

    it "skips tools without function key" do
      tools = [{"type" => JSON::Any.new("invalid")} of String => JSON::Any]

      result = Autobot::Providers::ToolConverter.build_tool_config(tools)

      result.should be_nil
    end
  end
end

private def build_tool(name : String, description : String, props : Hash(String, String)) : Hash(String, JSON::Any)
  properties = {} of String => JSON::Any
  props.each do |key, type|
    properties[key] = JSON::Any.new({"type" => JSON::Any.new(type)} of String => JSON::Any)
  end

  params = {
    "type"       => JSON::Any.new("object"),
    "properties" => JSON::Any.new(properties),
  } of String => JSON::Any

  {
    "type"     => JSON::Any.new("function"),
    "function" => JSON::Any.new({
      "name"        => JSON::Any.new(name),
      "description" => JSON::Any.new(description),
      "parameters"  => JSON::Any.new(params),
    } of String => JSON::Any),
  } of String => JSON::Any
end
