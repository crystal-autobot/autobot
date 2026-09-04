require "../spec_helper"

describe Autobot::Transcriber do
  describe "#initialize" do
    it "stores provider name" do
      t = Autobot::Transcriber.new(api_key: "test-key", provider: "openai")
      t.provider.should eq("openai")
    end

    it "defaults to openai provider" do
      t = Autobot::Transcriber.new(api_key: "test-key")
      t.provider.should eq("openai")
    end
  end

  describe "PROVIDERS" do
    it "has openai config" do
      config = Autobot::Transcriber::PROVIDERS["openai"]
      config[:url].should eq("https://api.openai.com/v1/audio/transcriptions")
      config[:model].should eq("whisper-1")
    end

    it "has groq config" do
      config = Autobot::Transcriber::PROVIDERS["groq"]
      config[:url].should eq("https://api.groq.com/openai/v1/audio/transcriptions")
      config[:model].should eq("whisper-large-v3-turbo")
    end
  end

  describe ".source" do
    it "prefers groq over openai when both chat providers have keys" do
      config = Autobot::Config::Config.from_yaml("providers:\n  groq:\n    api_key: gsk\n  openai:\n    api_key: sk\n")

      source = Autobot::Transcriber.source(config)
      source.should_not be_nil
      next unless source
      source.provider.should eq("groq")
      source.api_key.should eq("gsk")
      source.own_key.should be_false
    end

    it "is nil when no chat provider can transcribe" do
      Autobot::Transcriber.source(Autobot::Config::Config.from_yaml("providers:\n  anthropic:\n    api_key: ant\n")).should be_nil
      Autobot::Transcriber.source(Autobot::Config::Config.from_yaml("{}")).should be_nil
    end

    it "is nil when transcription is disabled" do
      config = Autobot::Config::Config.from_yaml("transcription:\n  enabled: false\nproviders:\n  groq:\n    api_key: gsk\n")

      Autobot::Transcriber.source(config).should be_nil
      Autobot::Transcriber.from_config(config).should be_nil
    end

    it "uses the pinned provider's chat key" do
      config = Autobot::Config::Config.from_yaml("transcription:\n  provider: openai\nproviders:\n  groq:\n    api_key: gsk\n  openai:\n    api_key: sk\n")

      source = Autobot::Transcriber.source(config)
      source.should_not be_nil
      next unless source
      source.provider.should eq("openai")
      source.api_key.should eq("sk")
    end

    it "is nil when the pinned provider has no key" do
      config = Autobot::Config::Config.from_yaml("transcription:\n  provider: openai\nproviders:\n  groq:\n    api_key: gsk\n")

      Autobot::Transcriber.source(config).should be_nil
    end

    it "uses its own key ahead of the chat providers" do
      config = Autobot::Config::Config.from_yaml("transcription:\n  api_key: own\nproviders:\n  groq:\n    api_key: gsk\n")

      source = Autobot::Transcriber.source(config)
      source.should_not be_nil
      next unless source
      source.provider.should eq("openai")
      source.api_key.should eq("own")
      source.own_key.should be_true
      Autobot::Transcriber.from_config(config).try(&.provider).should eq("openai")
    end

    it "pairs its own key with the pinned provider" do
      config = Autobot::Config::Config.from_yaml("transcription:\n  provider: groq\n  api_key: own\n")

      source = Autobot::Transcriber.source(config)
      source.should_not be_nil
      next unless source
      source.provider.should eq("groq")
      source.api_key.should eq("own")
    end

    it "is nil for an unknown provider" do
      config = Autobot::Config::Config.from_yaml("transcription:\n  provider: whisperx\n  api_key: own\n")

      Autobot::Transcriber.source(config).should be_nil
    end
  end

  describe "#transcribe" do
    it "returns nil for unknown provider" do
      t = Autobot::Transcriber.new(api_key: "test-key", provider: "unknown")
      result = t.transcribe(Bytes.new(10))
      result.should be_nil
    end
  end
end
