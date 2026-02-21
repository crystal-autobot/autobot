require "../../spec_helper"

# Minimal concrete channel for testing base class behavior.
private class StubChannel < Autobot::Channels::Channel
  def start : Nil
  end

  def stop : Nil
  end

  def send_message(message : Autobot::Bus::OutboundMessage) : Nil
  end
end

# Channel that overrides create_stream_callback to return a callback.
private class StreamableChannel < Autobot::Channels::Channel
  def start : Nil
  end

  def stop : Nil
  end

  def send_message(message : Autobot::Bus::OutboundMessage) : Nil
  end

  def create_stream_callback(chat_id : String) : Autobot::Providers::StreamCallback?
    Autobot::Providers::StreamCallback.new { |_delta| }
  end
end

describe "Channel base class" do
  describe "#create_stream_callback" do
    it "returns nil by default" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = StubChannel.new("test", bus)
      channel.create_stream_callback("chat1").should be_nil
    end

    it "can be overridden to return a callback" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = StreamableChannel.new("test", bus)
      channel.create_stream_callback("chat1").should_not be_nil
    end
  end
end

describe "Channels::Manager" do
  describe "#create_stream_callback" do
    it "returns nil for non-existent channel" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      config = Autobot::Config::Config.new
      manager = Autobot::Channels::Manager.new(config, bus)

      manager.create_stream_callback("nonexistent", "chat1").should be_nil
    end

    it "delegates to channel and returns its result" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      config = Autobot::Config::Config.new
      manager = Autobot::Channels::Manager.new(config, bus)

      # Inject a streamable channel directly
      manager.channels["streamable"] = StreamableChannel.new("streamable", bus)

      result = manager.create_stream_callback("streamable", "chat1")
      result.should_not be_nil
    end

    it "returns nil when channel does not support streaming" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      config = Autobot::Config::Config.new
      manager = Autobot::Channels::Manager.new(config, bus)

      # Inject a non-streaming channel
      manager.channels["stub"] = StubChannel.new("stub", bus)

      result = manager.create_stream_callback("stub", "chat1")
      result.should be_nil
    end
  end
end
