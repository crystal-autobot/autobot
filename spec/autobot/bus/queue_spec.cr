require "../../spec_helper"

describe Autobot::Bus::MessageBus do
  it "initializes without error" do
    bus = Autobot::Bus::MessageBus.new
    bus.stopped?.should be_false
  end

  it "publishes and consumes inbound messages" do
    bus = Autobot::Bus::MessageBus.new(capacity: 10)
    received = Channel(Autobot::Bus::InboundMessage).new(1)

    bus.consume_inbound do |msg|
      received.send(msg)
    end

    msg = Autobot::Bus::InboundMessage.new(
      channel: "test",
      sender_id: "user1",
      chat_id: "chat1",
      content: "hello"
    )
    bus.publish_inbound(msg)

    select
    when result = received.receive
      result.content.should eq("hello")
      result.channel.should eq("test")
    when timeout(2.seconds)
      raise "Timed out waiting for inbound message"
    end

    bus.stop
  end

  it "publishes and consumes outbound messages" do
    bus = Autobot::Bus::MessageBus.new(capacity: 10)
    received = Channel(Autobot::Bus::OutboundMessage).new(1)

    bus.consume_outbound do |msg|
      received.send(msg)
    end

    msg = Autobot::Bus::OutboundMessage.new(
      channel: "test",
      chat_id: "chat1",
      content: "reply"
    )
    bus.publish_outbound(msg)

    select
    when result = received.receive
      result.content.should eq("reply")
    when timeout(2.seconds)
      raise "Timed out waiting for outbound message"
    end

    bus.stop
  end

  it "stops gracefully" do
    bus = Autobot::Bus::MessageBus.new
    bus.stopped?.should be_false
    bus.stop
    bus.stopped?.should be_true
  end

  it "does not publish after stop" do
    bus = Autobot::Bus::MessageBus.new
    bus.stop

    msg = Autobot::Bus::InboundMessage.new(
      channel: "test",
      sender_id: "user",
      chat_id: "chat",
      content: "too late"
    )

    # Should not raise, just silently drop
    bus.publish_inbound(msg)
  end
end
