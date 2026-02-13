require "../../spec_helper"

# Minimal test tool for registry tests
class DummyTool < Autobot::Tools::Tool
  def name : String
    "dummy"
  end

  def description : String
    "A dummy tool for testing"
  end

  def parameters : Autobot::Tools::ToolSchema
    Autobot::Tools::ToolSchema.new(
      properties: {
        "input" => Autobot::Tools::PropertySchema.new(type: "string", description: "Input value"),
      },
      required: ["input"]
    )
  end

  def execute(params : Hash(String, JSON::Any)) : Autobot::Tools::ToolResult
    Autobot::Tools::ToolResult.success("echo: #{params["input"].as_s}")
  end
end

class FailingTool < Autobot::Tools::Tool
  def name : String
    "failing"
  end

  def description : String
    "A tool that always fails"
  end

  def parameters : Autobot::Tools::ToolSchema
    Autobot::Tools::ToolSchema.new
  end

  def execute(params : Hash(String, JSON::Any)) : Autobot::Tools::ToolResult
    raise "intentional failure"
  end
end

describe Autobot::Tools::Registry do
  it "starts empty" do
    registry = Autobot::Tools::Registry.new
    registry.size.should eq(0)
    registry.tool_names.should be_empty
  end

  it "registers a tool" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    registry.size.should eq(1)
    registry.has?("dummy").should be_true
  end

  it "gets a registered tool" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    tool = registry.get("dummy")
    tool.should_not be_nil
    tool.try(&.name).should eq("dummy")
  end

  it "returns nil for unknown tool" do
    registry = Autobot::Tools::Registry.new
    registry.get("unknown").should be_nil
  end

  it "unregisters a tool" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    registry.unregister("dummy")
    registry.has?("dummy").should be_false
    registry.size.should eq(0)
  end

  it "executes a registered tool" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    result = registry.execute("dummy", {"input" => JSON::Any.new("hello")})
    result.should eq("echo: hello")
  end

  it "returns error for unknown tool execution" do
    registry = Autobot::Tools::Registry.new
    result = registry.execute("unknown", {} of String => JSON::Any)
    result.should contain("Error: Tool 'unknown' not found")
  end

  it "returns error for invalid parameters" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    result = registry.execute("dummy", {} of String => JSON::Any)
    result.should contain("Error: Invalid parameters")
    result.should contain("missing required parameter 'input'")
  end

  it "handles tool execution failures gracefully" do
    registry = Autobot::Tools::Registry.new
    registry.register(FailingTool.new)
    result = registry.execute("failing", {} of String => JSON::Any)
    result.should contain("Error") # Generic for security
  end

  it "lists tool names" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    registry.register(FailingTool.new)
    registry.tool_names.sort.should eq(["dummy", "failing"])
  end

  it "gets tool definitions as schemas" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    defs = registry.definitions
    defs.size.should eq(1)
    defs[0]["type"].as_s.should eq("function")
    defs[0]["function"]["name"].as_s.should eq("dummy")
  end

  it "clears all tools" do
    registry = Autobot::Tools::Registry.new
    registry.register(DummyTool.new)
    registry.register(FailingTool.new)
    registry.clear
    registry.size.should eq(0)
  end
end
