require "../../spec_helper"

describe Autobot::Agent::Context::Builder do
  workspace = TestHelper.tmp_dir("context_test")

  after_all { FileUtils.rm_rf(workspace) }

  describe "#build_messages" do
    it "produces a compact system prompt" do
      builder = Autobot::Agent::Context::Builder.new(workspace)
      messages = builder.build_messages(
        history: [] of Hash(String, String),
        current_message: "Hello"
      )

      system_prompt = messages.first["content"].as_s
      system_prompt.should contain("autobot")
      system_prompt.should contain("Workspace:")
      # Compressed prompt should not contain the verbose tool list
      system_prompt.should_not contain("You have access to tools that allow you to:")
      # Should contain concise rules
      system_prompt.should contain("Batch independent tool calls")
    end

    it "builds text-only content when no media data" do
      builder = Autobot::Agent::Context::Builder.new(workspace)
      messages = builder.build_messages(
        history: [] of Hash(String, String),
        current_message: "Hello"
      )

      user_msg = messages.last
      user_msg["content"].as_s.should eq("Hello")
    end

    it "appends text media annotations when media has no data" do
      builder = Autobot::Agent::Context::Builder.new(workspace)
      media = [
        Autobot::Bus::MediaAttachment.new(type: "photo", url: "file_id_123"),
      ]

      messages = builder.build_messages(
        history: [] of Hash(String, String),
        current_message: "Check this",
        media: media
      )

      content = messages.last["content"].as_s
      content.should contain("Check this")
      content.should contain("[photo: file_id_123]")
    end

    it "builds multimodal content blocks when media has data" do
      builder = Autobot::Agent::Context::Builder.new(workspace)
      media = [
        Autobot::Bus::MediaAttachment.new(
          type: "photo",
          url: "file_id_123",
          mime_type: "image/jpeg",
          data: "aW1hZ2VieXRlcw=="
        ),
      ]

      messages = builder.build_messages(
        history: [] of Hash(String, String),
        current_message: "Analyze this image",
        media: media
      )

      content = messages.last["content"]
      blocks = content.as_a
      blocks.size.should eq(2)

      text_block = blocks[0]
      text_block["type"].as_s.should eq("text")
      text_block["text"].as_s.should eq("Analyze this image")

      image_block = blocks[1]
      image_block["type"].as_s.should eq("image_url")
      image_url = image_block["image_url"]["url"].as_s
      image_url.should eq("data:image/jpeg;base64,aW1hZ2VieXRlcw==")
    end

    it "builds multiple image blocks" do
      builder = Autobot::Agent::Context::Builder.new(workspace)
      media = [
        Autobot::Bus::MediaAttachment.new(
          type: "photo", mime_type: "image/jpeg", data: "img1data"
        ),
        Autobot::Bus::MediaAttachment.new(
          type: "photo", mime_type: "image/png", data: "img2data"
        ),
      ]

      messages = builder.build_messages(
        history: [] of Hash(String, String),
        current_message: "Compare these",
        media: media
      )

      blocks = messages.last["content"].as_a
      blocks.size.should eq(3) # 1 text + 2 images

      blocks[1]["image_url"]["url"].as_s.should contain("image/jpeg")
      blocks[2]["image_url"]["url"].as_s.should contain("image/png")
    end

    it "skips media without data in multimodal content" do
      builder = Autobot::Agent::Context::Builder.new(workspace)
      media = [
        Autobot::Bus::MediaAttachment.new(
          type: "photo", mime_type: "image/jpeg", data: "imgdata"
        ),
        Autobot::Bus::MediaAttachment.new(
          type: "document", url: "file_id_doc"
        ),
      ]

      messages = builder.build_messages(
        history: [] of Hash(String, String),
        current_message: "Here",
        media: media
      )

      blocks = messages.last["content"].as_a
      blocks.size.should eq(2) # 1 text + 1 image (document skipped)
    end

    it "handles empty text with image data" do
      builder = Autobot::Agent::Context::Builder.new(workspace)
      media = [
        Autobot::Bus::MediaAttachment.new(
          type: "photo", mime_type: "image/jpeg", data: "imgdata"
        ),
      ]

      messages = builder.build_messages(
        history: [] of Hash(String, String),
        current_message: "",
        media: media
      )

      blocks = messages.last["content"].as_a
      blocks.size.should eq(1) # only image, no empty text block
      blocks[0]["type"].as_s.should eq("image_url")
    end
  end

  describe "#add_assistant_message" do
    it "preserves extra_content on tool calls" do
      builder = Autobot::Agent::Context::Builder.new(workspace)

      extra = JSON::Any.new({
        "google" => JSON::Any.new({
          "thought_signature" => JSON::Any.new("sig_abc"),
        } of String => JSON::Any),
      } of String => JSON::Any)

      tool_call = Autobot::Providers::ToolCall.new(
        id: "tc_1",
        name: "read_file",
        arguments: {"path" => JSON::Any.new("test.cr")},
        extra_content: extra
      )

      messages = [] of Hash(String, JSON::Any)
      messages = builder.add_assistant_message(messages, "Let me check.", [tool_call])

      tc_data = messages.last["tool_calls"].as_a.first
      tc_data["id"].as_s.should eq("tc_1")
      tc_data["extra_content"]["google"]["thought_signature"].as_s.should eq("sig_abc")
    end

    it "omits extra_content when nil" do
      builder = Autobot::Agent::Context::Builder.new(workspace)

      tool_call = Autobot::Providers::ToolCall.new(
        id: "tc_2",
        name: "exec",
        arguments: {"cmd" => JSON::Any.new("ls")}
      )

      messages = [] of Hash(String, JSON::Any)
      messages = builder.add_assistant_message(messages, "Running.", [tool_call])

      tc_data = messages.last["tool_calls"].as_a.first
      tc_data["extra_content"]?.should be_nil
    end

    it "preserves reasoning_content" do
      builder = Autobot::Agent::Context::Builder.new(workspace)

      tool_call = Autobot::Providers::ToolCall.new(id: "tc_3", name: "search")

      messages = [] of Hash(String, JSON::Any)
      messages = builder.add_assistant_message(
        messages, "Thinking...", [tool_call],
        reasoning_content: "Step by step analysis"
      )

      messages.last["reasoning_content"].as_s.should eq("Step by step analysis")
    end
  end
end
