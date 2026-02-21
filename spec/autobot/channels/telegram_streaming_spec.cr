require "../../spec_helper"

# Controllable clock for deterministic throttle testing.
private class TestClock
  property now : Time = Time.utc

  def to_proc : Autobot::Channels::TelegramStreamingSession::Clock
    -> { @now }
  end

  def advance(span : Time::Span) : Nil
    @now += span
  end
end

private def build_session(
  chat_id : String = "123",
  api_calls : Array({String, Hash(String, String)}) = [] of {String, Hash(String, String)},
  clock : TestClock? = nil,
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
  if clock
    Autobot::Channels::TelegramStreamingSession.new(chat_id, api_caller, clock: clock.to_proc)
  else
    Autobot::Channels::TelegramStreamingSession.new(chat_id, api_caller)
  end
end

# Text long enough to trigger the initial message send.
private def initial_text : String
  "a" * Autobot::Channels::TelegramStreamingSession::MIN_INITIAL_LENGTH
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
    it "buffers short deltas without sending" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      session.on_delta("Hi")

      api_calls.size.should eq(0)
      session.message_id.should be_nil
    end

    it "sends initial message once buffer reaches threshold" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      session.on_delta(initial_text)

      api_calls.size.should eq(1)
      api_calls[0][0].should eq("sendMessage")
      api_calls[0][1]["chat_id"].should eq("123")
    end

    it "sets message_id from API response" do
      session = build_session

      session.on_delta(initial_text)

      session.message_id.should eq(42_i64)
    end

    it "accumulates text across calls" do
      clock = TestClock.new
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls, clock: clock)

      session.on_delta(initial_text)
      clock.advance(2.seconds)
      session.on_delta(" world")

      api_calls[0][0].should eq("sendMessage")
      api_calls[0][1]["text"].should eq(initial_text)

      api_calls.size.should eq(2)
      api_calls[1][0].should eq("editMessageText")
      api_calls[1][1]["text"].should eq("#{initial_text} world")
    end

    it "throttles edits within throttle period" do
      clock = TestClock.new
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls, clock: clock)

      session.on_delta(initial_text)
      # Don't advance clock — still within throttle period
      session.on_delta(" world")

      edit_calls = api_calls.select { |call| call[0] == "editMessageText" }
      edit_calls.size.should eq(0)
    end

    it "sends edit after throttle period elapses" do
      clock = TestClock.new
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls, clock: clock)

      session.on_delta(initial_text)
      session.on_delta(" world")

      edit_calls = api_calls.select { |call| call[0] == "editMessageText" }
      edit_calls.size.should eq(0)

      clock.advance(1.5.seconds)
      session.on_delta("!")

      edit_calls = api_calls.select { |call| call[0] == "editMessageText" }
      edit_calls.size.should eq(1)
      edit_calls[0][1]["text"].should eq("#{initial_text} world!")
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

      tail = Autobot::Channels::TelegramStreamingSession::TRUNCATION_TAIL
      sent_text = api_calls[0][1]["text"]
      sent_text.size.should eq(max_plain + tail.size)
      sent_text.should end_with(tail)
    end

    it "does not call API after deactivation" do
      clock = TestClock.new
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls, clock: clock)

      session.on_delta(initial_text)
      session.deactivate
      clock.advance(2.seconds)
      session.on_delta(" world")

      # Only the initial sendMessage, no edit after deactivation
      api_calls.size.should eq(1)
      api_calls[0][0].should eq("sendMessage")
    end

    it "sends multiple edits across throttle windows" do
      clock = TestClock.new
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls, clock: clock)

      session.on_delta(initial_text)
      clock.advance(1.5.seconds)
      session.on_delta("B")
      clock.advance(1.5.seconds)
      session.on_delta("C")

      send_calls = api_calls.select { |call| call[0] == "sendMessage" }
      edit_calls = api_calls.select { |call| call[0] == "editMessageText" }

      send_calls.size.should eq(1)
      edit_calls.size.should eq(2)
      edit_calls[0][1]["text"].should eq("#{initial_text}B")
      edit_calls[1][1]["text"].should eq("#{initial_text}BC")
    end

    it "incremental deltas trigger send once combined length reaches threshold" do
      api_calls = [] of {String, Hash(String, String)}
      session = build_session(api_calls: api_calls)

      # Send deltas that individually are below threshold
      threshold = Autobot::Channels::TelegramStreamingSession::MIN_INITIAL_LENGTH
      (threshold - 1).times { session.on_delta("x") }
      api_calls.size.should eq(0)

      # One more character pushes over the threshold
      session.on_delta("x")
      api_calls.size.should eq(1)
      api_calls[0][0].should eq("sendMessage")
      api_calls[0][1]["text"].should eq("x" * threshold)
    end
  end
end
