require "../../spec_helper"

private def with_roots(&)
  workspace = TestHelper.tmp_dir("roots")
  Dir.mkdir_p(workspace / "notes")
  Dir.mkdir_p(workspace / "inbox")
  Dir.mkdir_p(workspace / "memory")
  File.write(workspace / "notes" / "a.md", "note")
  File.write(workspace / "memory" / "MEMORY.md", "secret")
  roots = Autobot::Tools.resolve_roots(["notes", "inbox"], workspace)
  yield Autobot::Tools::SandboxExecutor.new(workspace, false, roots), workspace
ensure
  FileUtils.rm_rf(workspace) if workspace
end

describe Autobot::Tools::SandboxExecutor do
  describe "filesystem roots" do
    it "allows reads, writes and listings inside a root" do
      with_roots do |executor, workspace|
        executor.read_file((workspace / "notes" / "a.md").to_s).content.should eq("note")
        executor.write_file((workspace / "inbox" / "b.txt").to_s, "x").success?.should be_true
        executor.list_dir((workspace / "notes").to_s).success?.should be_true
      end
    end

    it "checks relative paths against the workspace" do
      with_roots do |executor, _|
        executor.read_file("memory/MEMORY.md").content.should contain("outside the allowed directories")
        executor.read_file("notes/a.md").content.should_not contain("outside the allowed directories")
      end
    end

    it "refuses paths outside every root, including traversal" do
      with_roots do |executor, workspace|
        result = executor.read_file((workspace / "memory" / "MEMORY.md").to_s)
        result.success?.should be_false
        result.content.should contain("outside the allowed directories (notes, inbox)")

        executor.read_file("notes/../memory/MEMORY.md").success?.should be_false
        executor.write_file((workspace / "SOUL.md").to_s, "x").success?.should be_false
        executor.list_dir(workspace.to_s).success?.should be_false
        executor.read_file_base64("/etc/hosts").success?.should be_false
      end
    end

    it "does not restrict commands" do
      with_roots do |executor, _|
        executor.exec("echo ok").content.strip.should eq("ok")
      end
    end

    it "keeps everything open without roots" do
      workspace = TestHelper.tmp_dir("noroots")
      begin
        File.write(workspace / "x.txt", "x")
        Autobot::Tools::SandboxExecutor.new(workspace, false).read_file((workspace / "x.txt").to_s).success?.should be_true
      ensure
        FileUtils.rm_rf(workspace)
      end
    end
  end
end
