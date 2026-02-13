require "../../spec_helper"

describe Autobot::Tools::ReadFileTool do
  it "reads a file successfully" do
    tmp = TestHelper.tmp_dir
    file = tmp / "test.txt"
    File.write(file, "hello world")

    tool = Autobot::Tools::ReadFileTool.new
    result = tool.execute({"path" => JSON::Any.new(file.to_s)})
    result.success?.should be_true
    result.content.should eq("hello world")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns error for nonexistent file" do
    tool = Autobot::Tools::ReadFileTool.new
    result = tool.execute({"path" => JSON::Any.new("/nonexistent/file.txt")})
    result.error?.should be_true
    result.content.should contain("File not found")
  end

  it "returns error for directories" do
    tmp = TestHelper.tmp_dir

    tool = Autobot::Tools::ReadFileTool.new
    result = tool.execute({"path" => JSON::Any.new(tmp.to_s)})
    result.error?.should be_true
    result.content.should contain("not a file")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "enforces workspace sandboxing" do
    tmp = TestHelper.tmp_dir
    File.write(tmp / "allowed.txt", "ok")
    outside = TestHelper.tmp_dir
    File.write(outside / "secret.txt", "forbidden")

    tool = Autobot::Tools::ReadFileTool.new(allowed_dir: tmp)
    result = tool.execute({"path" => JSON::Any.new((outside / "secret.txt").to_s)})
    result.access_denied?.should be_true
    result.content.should contain("Access denied")
  ensure
    FileUtils.rm_rf(tmp) if tmp
    FileUtils.rm_rf(outside) if outside
  end

  it "has correct tool metadata" do
    tool = Autobot::Tools::ReadFileTool.new
    tool.name.should eq("read_file")
    tool.description.should_not be_empty
  end
end

describe Autobot::Tools::WriteFileTool do
  it "writes a file successfully" do
    tmp = TestHelper.tmp_dir
    file = tmp / "output.txt"

    tool = Autobot::Tools::WriteFileTool.new
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

    tool = Autobot::Tools::WriteFileTool.new
    tool.execute({
      "path"    => JSON::Any.new(file.to_s),
      "content" => JSON::Any.new("deep write"),
    })

    File.exists?(file).should be_true
    File.read(file).should eq("deep write")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "enforces workspace sandboxing" do
    tmp = TestHelper.tmp_dir
    outside = TestHelper.tmp_dir

    tool = Autobot::Tools::WriteFileTool.new(allowed_dir: tmp)
    result = tool.execute({
      "path"    => JSON::Any.new((outside / "hack.txt").to_s),
      "content" => JSON::Any.new("data"),
    })
    result.access_denied?.should be_true
    result.content.should contain("Access denied")
  ensure
    FileUtils.rm_rf(tmp) if tmp
    FileUtils.rm_rf(outside) if outside
  end
end

describe Autobot::Tools::EditFileTool do
  it "replaces text in a file" do
    tmp = TestHelper.tmp_dir
    file = tmp / "edit.txt"
    File.write(file, "Hello World")

    tool = Autobot::Tools::EditFileTool.new
    result = tool.execute({
      "path"     => JSON::Any.new(file.to_s),
      "old_text" => JSON::Any.new("World"),
      "new_text" => JSON::Any.new("Crystal"),
    })

    result.success?.should be_true
    result.content.should contain("Successfully edited")
    File.read(file).should eq("Hello Crystal")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns error when old_text not found" do
    tmp = TestHelper.tmp_dir
    file = tmp / "edit.txt"
    File.write(file, "Hello World")

    tool = Autobot::Tools::EditFileTool.new
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

    tool = Autobot::Tools::EditFileTool.new
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
    tool = Autobot::Tools::EditFileTool.new
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

    tool = Autobot::Tools::ListDirTool.new
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
    tool = Autobot::Tools::ListDirTool.new
    result = tool.execute({"path" => JSON::Any.new("/nonexistent/dir")})
    result.error?.should be_true
    result.content.should contain("Directory not found")
  end

  it "handles empty directory" do
    tmp = TestHelper.tmp_dir

    tool = Autobot::Tools::ListDirTool.new
    result = tool.execute({"path" => JSON::Any.new(tmp.to_s)})
    result.success?.should be_true
    result.content.should contain("empty")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
