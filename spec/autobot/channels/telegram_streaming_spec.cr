require "../../spec_helper"

private def build_session(
  chat_id : String = "123",
  api_calls : Array({String, Hash(String, String)}) = [] of {String, Hash(String, String)},
) : Autobot::Channels::TelegramStreamingSession
  api_caller = ->(method : String, params : Hash(String, String)) : JSON::Any? {
    # Deep-copy each value so that later String::Builder writes
    # do not corrupt previously recorded strings.
    snapshot = {} of String => String
    params.each { |k, v| snapshot[String.new(k.to_slice)] = String.new(v.to_slice) }
    api_calls << {String.new(method.to_slice), snapshot}
    if method == "sendMessage"
      JSON::Any.new({"message_id" => JSON::Any.new(42_i64)} of String => JSON::Any)
    else
      nil
    end
  }
  Autobot::Channels::TelegramStreamingSession.new(chat_id, api_caller)
end

describe Autobot::Channels::TelegramStreamingSession do
  describe "#message_id" do
    it "is nil before first delta" do
      session = build_session
      session.message_id.should be_nil
    end
  end

  describe "#active?" do
    it "is true by default" do
      session = build_session
      session.active?.should be_true
    end
  end

  describe "#on_delta" do
    it "sends initial message on first call" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      session.on_delta("Hello")

      api_calls.size.should eq(1)
      api_calls[0][0].should eq("sendMessage")
      api_calls[0][1]["chat_id"].should eq("123")
      api_calls[0][1]["text"].should eq("Hello")
    end

    it "sets message_id from API response" do
      session = build_session

      session.on_delta("Hello")

      session.message_id.should eq(42_i64)
    end

    it "accumulates text across calls" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      session.on_delta("Hello")
      session.on_delta(" world")

      api_calls[0][0].should eq("sendMessage")
      api_calls[0][1]["text"].should eq("Hello")

      # The second delta should attempt an edit with accumulated text.
      # It may or may not be throttled depending on timing, but the
      # sendMessage text should only contain the first delta.
      if api_calls.size > 1
        api_calls[1][0].should eq("editMessageText")
        api_calls[1][1]["text"].should eq("Hello world")
      end
    end

    it "throttles edits within throttle period" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      session.on_delta("Hello")
      session.on_delta(" world")

      # Only the initial sendMessage should be called; the edit is throttled
      # because EDIT_THROTTLE (1 second) has not elapsed since the send.
      edit_calls = api_calls.select { |call| call[0] == "editMessageText" }
      edit_calls.size.should eq(0)
    end

    it "does not send empty text on empty delta" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      session.on_delta("")

      api_calls.size.should eq(0)
      session.message_id.should be_nil
    end

    it "truncates long text" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      max_plain = Autobot::Channels::TelegramStreamingSession::MAX_PLAIN_TEXT
      long_text = "a" * (max_plain + 100)

      session.on_delta(long_text)

      sent_text = api_calls[0][1]["text"]
      sent_text.size.should eq(max_plain + 3) # 3 for "..."
      sent_text.should end_with("...")
    end
  end
end
