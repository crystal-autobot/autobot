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

  describe "#transcribe" do
    it "returns nil for unknown provider" do
      t = Autobot::Transcriber.new(api_key: "test-key", provider: "unknown")
      result = t.transcribe(Bytes.new(10))
      result.should be_nil
    end
  end
end
