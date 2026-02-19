require "../../spec_helper"

describe Autobot::Agent::Context::Builder do
  workspace = TestHelper.tmp_dir("context_test")

  after_all { FileUtils.rm_rf(workspace) }

  describe "#build_messages" do
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
end
