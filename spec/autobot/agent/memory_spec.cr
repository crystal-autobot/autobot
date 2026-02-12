require "../../spec_helper"

describe Autobot::Agent::MemoryStore do
  it "initializes with empty memory" do
    tmp = TestHelper.tmp_dir
    store = Autobot::Agent::MemoryStore.new(workspace: tmp)
    store.read_long_term.should eq("")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "writes and reads long-term memory" do
    tmp = TestHelper.tmp_dir
    store = Autobot::Agent::MemoryStore.new(workspace: tmp)

    store.write_long_term("# Facts\n- Crystal is fast\n- Types are good")
    content = store.read_long_term
    content.should contain("Crystal is fast")
    content.should contain("Types are good")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "overwrites long-term memory" do
    tmp = TestHelper.tmp_dir
    store = Autobot::Agent::MemoryStore.new(workspace: tmp)

    store.write_long_term("first version")
    store.write_long_term("second version")
    store.read_long_term.should eq("second version")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "appends to history" do
    tmp = TestHelper.tmp_dir
    store = Autobot::Agent::MemoryStore.new(workspace: tmp)

    store.append_history("2025-01-01: User asked about weather")
    store.append_history("2025-01-02: User asked about news")

    history_path = tmp / "memory" / "HISTORY.md"
    content = File.read(history_path)
    content.should contain("weather")
    content.should contain("news")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns memory context for system prompt" do
    tmp = TestHelper.tmp_dir
    store = Autobot::Agent::MemoryStore.new(workspace: tmp)

    store.write_long_term("Key fact: autobot uses Crystal")
    context = store.memory_context
    context.should contain("Long-term Memory")
    context.should contain("autobot uses Crystal")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns empty context when no memory" do
    tmp = TestHelper.tmp_dir
    store = Autobot::Agent::MemoryStore.new(workspace: tmp)
    store.memory_context.should eq("")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "creates memory directory structure" do
    tmp = TestHelper.tmp_dir
    Autobot::Agent::MemoryStore.new(workspace: tmp)
    Dir.exists?(tmp / "memory").should be_true
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
