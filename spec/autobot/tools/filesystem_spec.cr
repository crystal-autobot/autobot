require "../../spec_helper"

describe Autobot::Tools::ReadFileTool do
  it "reads a file successfully" do
    tmp = TestHelper.tmp_dir
    file = tmp / "test.txt"
    File.write(file, "hello world")

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::ReadFileTool.new(executor)
    result = tool.execute({"path" => JSON::Any.new(file.to_s)})
    result.success?.should be_true
    result.content.should eq("hello world")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns error for nonexistent file" do
    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::ReadFileTool.new(executor)
    result = tool.execute({"path" => JSON::Any.new("/nonexistent/file.txt")})
    result.error?.should be_true
    result.content.should contain("not found")
  end

  it "returns error for directories" do
    tmp = TestHelper.tmp_dir

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::ReadFileTool.new(executor)
    result = tool.execute({"path" => JSON::Any.new(tmp.to_s)})
    result.error?.should be_true
    result.content.should contain("not a file")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end

describe Autobot::Tools::WriteFileTool do
  it "writes content to a file" do
    tmp = TestHelper.tmp_dir
    file = tmp / "write.txt"

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::WriteFileTool.new(executor)
    result = tool.execute({
      "path"    => JSON::Any.new(file.to_s),
      "content" => JSON::Any.new("written content"),
    })

    result.success?.should be_true
    result.content.should contain("Successfully wrote")
    File.read(file).should eq("written content")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "creates parent directories" do
    tmp = TestHelper.tmp_dir
    file = tmp / "sub" / "dir" / "file.txt"

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::WriteFileTool.new(executor)
    tool.execute({
      "path"    => JSON::Any.new(file.to_s),
      "content" => JSON::Any.new("deep write"),
    })

    File.exists?(file).should be_true
    File.read(file).should eq("deep write")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end

describe Autobot::Tools::EditFileTool do
  it "replaces text in a file" do
    tmp = TestHelper.tmp_dir
    file = tmp / "edit.txt"
    File.write(file, "Hello World")

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::EditFileTool.new(executor)
    result = tool.execute({
      "path"     => JSON::Any.new(file.to_s),
      "old_text" => JSON::Any.new("World"),
      "new_text" => JSON::Any.new("Crystal"),
    })

    result.success?.should be_true
    File.read(file).should eq("Hello Crystal")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns error when text not found" do
    tmp = TestHelper.tmp_dir
    file = tmp / "edit.txt"
    File.write(file, "Hello World")

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::EditFileTool.new(executor)
    result = tool.execute({
      "path"     => JSON::Any.new(file.to_s),
      "old_text" => JSON::Any.new("nonexistent"),
      "new_text" => JSON::Any.new("replacement"),
    })

    result.error?.should be_true
    result.content.should contain("not found")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "warns on ambiguous matches" do
    tmp = TestHelper.tmp_dir
    file = tmp / "edit.txt"
    File.write(file, "hello hello hello")

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::EditFileTool.new(executor)
    result = tool.execute({
      "path"     => JSON::Any.new(file.to_s),
      "old_text" => JSON::Any.new("hello"),
      "new_text" => JSON::Any.new("world"),
    })

    result.error?.should be_true
    result.content.should contain("appears 3 times")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns error for nonexistent file" do
    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::EditFileTool.new(executor)
    result = tool.execute({
      "path"     => JSON::Any.new("/nonexistent.txt"),
      "old_text" => JSON::Any.new("x"),
      "new_text" => JSON::Any.new("y"),
    })
    result.error?.should be_true
    result.content.should contain("File not found")
  end
end

describe Autobot::Tools::ListDirTool do
  it "lists directory contents" do
    tmp = TestHelper.tmp_dir
    File.write(tmp / "file1.txt", "")
    File.write(tmp / "file2.cr", "")
    Dir.mkdir(tmp / "subdir")

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::ListDirTool.new(executor)
    result = tool.execute({"path" => JSON::Any.new(tmp.to_s)})

    result.success?.should be_true
    result.content.should contain("file1.txt")
    result.content.should contain("file2.cr")
    result.content.should contain("[dir]")
    result.content.should contain("subdir")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns error for nonexistent directory" do
    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::ListDirTool.new(executor)
    result = tool.execute({"path" => JSON::Any.new("/nonexistent/dir")})
    result.error?.should be_true
    result.content.should contain("Directory not found")
  end

  it "handles empty directory" do
    tmp = TestHelper.tmp_dir

    executor = Autobot::Tools::SandboxExecutor.new(nil, nil)
    tool = Autobot::Tools::ListDirTool.new(executor)
    result = tool.execute({"path" => JSON::Any.new(tmp.to_s)})
    result.success?.should be_true
    result.content.should contain("empty")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
