require "../../spec_helper"

private class MockSubagentProvider < Autobot::Providers::HttpProvider
  def initialize
    super(api_key: "test-key", model: "mock-model")
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":"Subagent finished"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}))
  end
end

private class BlockingSubagentManager < Autobot::Agent::SubagentManager
  getter started = Channel(Nil).new
  getter gate = Channel(Nil).new
  getter completed = Channel(Nil).new

  private def run_subagent(
    task_id : String,
    task : String,
    label : String,
    origin : Hash(String, String),
  ) : Nil
    @started.send(nil)
    @gate.receive
  end

  private def run_and_untrack(
    task_id : String,
    task : String,
    label : String,
    origin : Hash(String, String),
  ) : Nil
    super
  ensure
    @completed.send(nil)
  end
end

private class FailingSubagentManager < Autobot::Agent::SubagentManager
  getter completed = Channel(Nil).new

  private def run_subagent(
    task_id : String,
    task : String,
    label : String,
    origin : Hash(String, String),
  ) : Nil
    raise "Simulated background subagent failure"
  end

  private def run_and_untrack(
    task_id : String,
    task : String,
    label : String,
    origin : Hash(String, String),
  ) : Nil
    super
  ensure
    @completed.send(nil)
  end
end

private class TrackingSubagentManager < Autobot::Agent::SubagentManager
  getter completed = Channel(String).new(100)

  private def run_and_untrack(
    task_id : String,
    task : String,
    label : String,
    origin : Hash(String, String),
  ) : Nil
    super
  ensure
    @completed.send(task_id)
  end
end

describe Autobot::Agent::SubagentManager do
  it "tracks running task count while subagent is running and cleans up on completion" do
    tmp = TestHelper.tmp_dir
    bus = Autobot::Bus::MessageBus.new(capacity: 10)
    provider = MockSubagentProvider.new
    manager = BlockingSubagentManager.new(
      provider: provider,
      workspace: tmp,
      bus: bus,
      sandbox_config: "none",
    )

    manager.running_count.should eq(0)
    manager.spawn("Do work", label: "Worker 1")

    # Wait until background fiber begins executing
    manager.started.receive
    manager.running_count.should eq(1)

    # Release gate and wait for fiber completion
    manager.gate.send(nil)
    manager.completed.receive

    manager.running_count.should eq(0)
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "guarantees running task cleanup even if subagent fiber raises an error" do
    tmp = TestHelper.tmp_dir
    bus = Autobot::Bus::MessageBus.new(capacity: 10)
    provider = MockSubagentProvider.new
    manager = FailingSubagentManager.new(
      provider: provider,
      workspace: tmp,
      bus: bus,
      sandbox_config: "none",
    )

    manager.running_count.should eq(0)
    manager.spawn("Failing task", label: "Failing Worker")

    # Wait until background fiber finishes and cleans up
    manager.completed.receive

    manager.running_count.should eq(0)
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "handles concurrent spawn and completion across multiple fibers safely" do
    tmp = TestHelper.tmp_dir
    bus = Autobot::Bus::MessageBus.new(capacity: 100)
    provider = MockSubagentProvider.new
    manager = TrackingSubagentManager.new(
      provider: provider,
      workspace: tmp,
      bus: bus,
      sandbox_config: "none",
    )

    concurrent_tasks = 25
    spawn_done = Channel(Nil).new

    concurrent_tasks.times do |i|
      spawn do
        manager.spawn("Task #{i}", label: "T#{i}")
        spawn_done.send(nil)
      end
    end

    concurrent_tasks.times { spawn_done.receive }

    # Deterministically wait for all 25 subagent background fibers to complete
    concurrent_tasks.times { manager.completed.receive }

    manager.running_count.should eq(0)
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
