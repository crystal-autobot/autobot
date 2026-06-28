require "../../spec_helper"
require "../../../src/autobot/plugins/chat_log"
require "../../../src/autobot/plugins/system_info"
require "../../../src/autobot/plugins/tts"

describe Autobot::Plugins::ChatLogTool do
  it "retrieves recent chat logs" do
    tmp = TestHelper.tmp_dir
    log_dir = tmp / "data" / "chat_logs"
    Dir.mkdir_p(log_dir)
    File.write((log_dir / "telegram_-100123456.log").to_s, "line1\nline2\nline3\n")

    tool = Autobot::Plugins::ChatLogTool.new(tmp)
    res = tool.execute({
      "chat_id" => JSON::Any.new("-100123456"),
      "limit"   => JSON::Any.new(2_i64),
    })

    res.success?.should be_true
    res.content.should contain("line2")
    res.content.should contain("line3")
    res.content.should_not contain("line1")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns message when no logs found" do
    tmp = TestHelper.tmp_dir
    tool = Autobot::Plugins::ChatLogTool.new(tmp)
    res = tool.execute({"chat_id" => JSON::Any.new("nonexistent")})
    res.success?.should be_true
    res.content.should contain("No recent chat logs found")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "prevents directory traversal attacks" do
    tmp = TestHelper.tmp_dir
    tool = Autobot::Plugins::ChatLogTool.new(tmp)
    res = tool.execute({"chat_id" => JSON::Any.new("../../../etc/passwd")})
    res.success?.should be_false
    res.content.should contain("Invalid chat_id format")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end

describe Autobot::Plugins::SystemInfoTool do
  it "returns host system metrics" do
    tmp = TestHelper.tmp_dir
    tool = Autobot::Plugins::SystemInfoTool.new(tmp)
    res = tool.execute({} of String => JSON::Any)
    res.success?.should be_true
    res.content.should contain("Host Metrics")
    res.content.should contain("Uptime")
    res.content.should contain("Memory Usage")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end

describe Autobot::Plugins::TextToSpeechTool do
  it "exposes parameters schema" do
    tmp = TestHelper.tmp_dir
    tool = Autobot::Plugins::TextToSpeechTool.new(tmp)
    tool.parameters.properties.has_key?("text").should be_true
    tool.parameters.properties.has_key?("lang").should be_true
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
