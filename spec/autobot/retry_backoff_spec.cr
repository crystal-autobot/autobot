require "../spec_helper"

describe Autobot::RetryBackoff do
  it "doubles the delay on each retry up to the maximum" do
    backoff = Autobot::RetryBackoff.new(2.seconds, 10.seconds)

    backoff.next_delay.should eq(2.seconds)
    backoff.next_delay.should eq(4.seconds)
    backoff.next_delay.should eq(8.seconds)
    backoff.next_delay.should eq(10.seconds)
    backoff.next_delay.should eq(10.seconds)
  end

  it "returns to the initial delay after a reset" do
    backoff = Autobot::RetryBackoff.new(2.seconds, 10.seconds)
    backoff.next_delay
    backoff.next_delay

    backoff.reset

    backoff.next_delay.should eq(2.seconds)
  end
end
