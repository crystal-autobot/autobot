require "spec"
require "json"
require "file_utils"
require "../src/autobot"

::Log.setup(::Log::Severity::None)

# Shared test helper for temporary directories
module TestHelper
  # Create a temporary directory for test isolation.
  # Returns the path. Caller should clean up with FileUtils.rm_rf.
  def self.tmp_dir(prefix = "autobot_test") : Path
    dir = Path.new(Dir.tempdir) / "#{prefix}_#{Random::Secure.hex(4)}"
    Dir.mkdir_p(dir)
    dir
  end
end
