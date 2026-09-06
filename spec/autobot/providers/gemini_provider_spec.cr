require "../../spec_helper"

class TestableGeminiProvider < Autobot::Providers::GeminiProvider
  def test_map_messages_to_native(messages)
    map_messages_to_native(messages)
  end
end

describe Autobot::Providers::GeminiProvider do
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
end
