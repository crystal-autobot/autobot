require "../../spec_helper"

describe Autobot::Tools::ImageGenerationTool do
  it "has correct name" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )
    tool.name.should eq("generate_image")
  end

  it "has a description" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )
    tool.description.should_not be_empty
  end

  it "defines required prompt parameter" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )
    schema = tool.parameters
    schema.required.should contain("prompt")
  end

  it "defines optional size parameter with enum values" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )
    schema = tool.parameters
    size_prop = schema.properties["size"]
    enum_vals = size_prop.enum_values
    enum_vals.should_not be_nil
    enum_vals.as(Array(String)).should contain("1024x1024")
  end

  it "returns error when send callback is not configured" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )
    tool.set_context("telegram", "123")

    result = tool.execute({"prompt" => JSON::Any.new("a sunset")})
    result.success?.should be_false
    result.content.should contain("not configured")
  end

  it "returns error when no channel context is set" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )

    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }

    result = tool.execute({"prompt" => JSON::Any.new("a sunset")})
    result.success?.should be_false
    result.content.should contain("No target channel/chat")
  end

  it "returns error for unsupported provider" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "anthropic",
    )

    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }
    tool.set_context("telegram", "123")

    result = tool.execute({"prompt" => JSON::Any.new("a sunset")})
    result.success?.should be_false
    result.content.should contain("Unsupported image generation provider")
  end

  it "validates prompt is not empty" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )

    errors = tool.validate_params({"prompt" => JSON::Any.new("")})
    errors.should_not be_empty
  end

  it "validates size enum values" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )

    errors = tool.validate_params({
      "prompt" => JSON::Any.new("test"),
      "size"   => JSON::Any.new("invalid_size"),
    })
    errors.should_not be_empty
  end

  it "accepts valid size values" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )

    errors = tool.validate_params({
      "prompt" => JSON::Any.new("test"),
      "size"   => JSON::Any.new("1024x1024"),
    })
    errors.should be_empty
  end

  it "generates correct schema for function calling" do
    tool = Autobot::Tools::ImageGenerationTool.new(
      api_key: "test-key",
      provider_name: "openai",
    )

    schema = tool.to_schema
    schema["type"].should eq(JSON::Any.new("function"))
    func = schema["function"].as_h
    func["name"].should eq(JSON::Any.new("generate_image"))
  end
end
