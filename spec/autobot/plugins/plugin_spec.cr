require "../../spec_helper"

# Test plugin implementation
class TestPlugin < Autobot::Plugins::Plugin
  property? setup_called : Bool = false
  property? start_called : Bool = false
  property? stop_called : Bool = false

  def name : String
    "test_plugin"
  end

  def description : String
    "A test plugin"
  end

  def version : String
    "1.0.0"
  end

  def setup(context : Autobot::Plugins::PluginContext) : Nil
    @setup_called = true
  end

  def start : Nil
    @start_called = true
  end

  def stop : Nil
    @stop_called = true
  end
end

class AnotherPlugin < Autobot::Plugins::Plugin
  def name : String
    "another"
  end

  def description : String
    "Another plugin"
  end

  def version : String
    "0.2.0"
  end
end

describe Autobot::Plugins::Plugin do
  it "exposes metadata" do
    plugin = TestPlugin.new
    meta = plugin.metadata
    meta["name"].should eq("test_plugin")
    meta["description"].should eq("A test plugin")
    meta["version"].should eq("1.0.0")
  end
end

describe Autobot::Plugins::PluginContext do
  it "provides access to config and tool registry" do
    config = Autobot::Config::Config.new
    registry = Autobot::Tools::Registry.new
    tmp = TestHelper.tmp_dir

    context = Autobot::Plugins::PluginContext.new(
      config: config,
      tool_registry: registry,
      workspace: tmp
    )

    context.config.should eq(config)
    context.tool_registry.should eq(registry)
    context.workspace.should eq(tmp)
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end

describe Autobot::Plugins::Registry do
  it "registers a plugin" do
    registry = Autobot::Plugins::Registry.new
    registry.register(TestPlugin.new)
    registry.size.should eq(1)
    registry.has?("test_plugin").should be_true
  end

  it "gets a plugin by name" do
    registry = Autobot::Plugins::Registry.new
    registry.register(TestPlugin.new)
    plugin = registry.get("test_plugin")
    plugin.should_not be_nil
    plugin.try(&.name).should eq("test_plugin")
  end

  it "returns nil for unknown plugin" do
    registry = Autobot::Plugins::Registry.new
    registry.get("unknown").should be_nil
  end

  it "lists plugin names" do
    registry = Autobot::Plugins::Registry.new
    registry.register(TestPlugin.new)
    registry.register(AnotherPlugin.new)
    registry.plugin_names.sort.should eq(["another", "test_plugin"])
  end

  it "calls setup on all plugins" do
    registry = Autobot::Plugins::Registry.new
    plugin = TestPlugin.new
    registry.register(plugin)

    config = Autobot::Config::Config.new
    tool_registry = Autobot::Tools::Registry.new
    tmp = TestHelper.tmp_dir
    context = Autobot::Plugins::PluginContext.new(config: config, tool_registry: tool_registry, workspace: tmp)

    registry.setup_all(context)
    plugin.setup_called?.should be_true
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "calls start on all plugins" do
    registry = Autobot::Plugins::Registry.new
    plugin = TestPlugin.new
    registry.register(plugin)
    registry.start_all
    plugin.start_called?.should be_true
  end

  it "calls stop on all plugins" do
    registry = Autobot::Plugins::Registry.new
    plugin = TestPlugin.new
    registry.register(plugin)
    registry.stop_all
    plugin.stop_called?.should be_true
  end

  it "returns metadata for all plugins" do
    registry = Autobot::Plugins::Registry.new
    registry.register(TestPlugin.new)
    registry.register(AnotherPlugin.new)

    meta = registry.all_metadata
    meta.size.should eq(2)
    meta.map { |plugin_meta| plugin_meta["name"] }.sort!.should eq(["another", "test_plugin"])
  end

  it "replaces plugin with same name" do
    registry = Autobot::Plugins::Registry.new
    registry.register(TestPlugin.new)
    registry.register(TestPlugin.new)
    registry.size.should eq(1)
  end
end

describe Autobot::Plugins::Loader do
  it "registers plugins for later loading" do
    Autobot::Plugins::Loader.clear_pending
    plugin = TestPlugin.new
    Autobot::Plugins::Loader.register(plugin)
    Autobot::Plugins::Loader.pending.size.should eq(1)
    Autobot::Plugins::Loader.clear_pending
  end

  it "loads all pending plugins into registry" do
    Autobot::Plugins::Loader.clear_pending
    Autobot::Plugins::Loader.register(TestPlugin.new)
    Autobot::Plugins::Loader.register(AnotherPlugin.new)

    registry = Autobot::Plugins::Registry.new
    config = Autobot::Config::Config.new
    tool_registry = Autobot::Tools::Registry.new
    tmp = TestHelper.tmp_dir
    context = Autobot::Plugins::PluginContext.new(config: config, tool_registry: tool_registry, workspace: tmp)

    Autobot::Plugins::Loader.load_all(registry, context)
    registry.size.should eq(2)
    Autobot::Plugins::Loader.pending.should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
    Autobot::Plugins::Loader.clear_pending
  end

  it "clears pending list" do
    Autobot::Plugins::Loader.clear_pending
    Autobot::Plugins::Loader.register(TestPlugin.new)
    Autobot::Plugins::Loader.clear_pending
    Autobot::Plugins::Loader.pending.should be_empty
  end
end
