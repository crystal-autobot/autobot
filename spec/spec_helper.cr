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

def text_response(content : String) : String
  %({"choices":[{"message":{"content":#{content.to_json}},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}})
end

def tool_call_response(tool_name : String, tool_id : String, arguments : String = "{}") : String
  %({"choices":[{"message":{"content":"","tool_calls":[{"id":"#{tool_id}","type":"function","function":{"name":"#{tool_name}","arguments":"#{arguments.gsub('"', "\\\"")}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}})
end
