require "log"
require "json"
require "./log_sanitizer"

module Autobot
  module Logging
    alias Level = ::Log::Severity

    LOG_FILENAME = "autobot.log"

    # Setup logging backends.
    #
    # Always enables a colored console backend. If `log_dir` is given,
    # also writes structured JSON to a file in that directory.
    def self.setup(log_level : Level = Level::Info, log_dir : String? = nil) : Nil
      ::Log.setup do |config|
        config.bind("*", log_level, ConsoleBackend.new)

        if log_dir
          log_path = File.join(log_dir, LOG_FILENAME)
          Dir.mkdir_p(File.dirname(log_path)) unless Dir.exists?(File.dirname(log_path))
          config.bind("*", log_level, JSONFileBackend.new(File.open(log_path, "a")))
        end
      end
    end

    private class ConsoleBackend < ::Log::Backend
      def initialize
        super(:sync)
      end

      def write(entry : ::Log::Entry) : Nil
        io = STDERR
        timestamp = entry.timestamp.to_s("%H:%M:%S")
        severity = format_severity(entry.severity)
        sanitized_msg = LogSanitizer.sanitize(entry.message)

        io << '[' << timestamp << "] " << severity << ' ' << entry.source << " - " << sanitized_msg

        if ex = entry.exception
          sanitized_ex_msg = LogSanitizer.sanitize(ex.message || "")
          io << " — " << ex.class.name << ": " << sanitized_ex_msg
        end
        io << '\n'
      end

      private def format_severity(severity : ::Log::Severity) : String
        case severity
        when .trace? then "TRACE"
        when .debug? then "DEBUG"
        when .info?  then " INFO"
        when .warn?  then " WARN"
        when .error? then "ERROR"
        when .fatal? then "FATAL"
        else              "  ???"
        end
      end
    end

    private class JSONFileBackend < ::Log::Backend
      def initialize(@io : IO)
        super(:sync)
      end

      def write(entry : ::Log::Entry) : Nil
        JSON.build(@io) do |json|
          json.object do
            json.field "ts", entry.timestamp.to_rfc3339
            json.field "level", entry.severity.to_s
            json.field "source", entry.source
            json.field "msg", LogSanitizer.sanitize(entry.message)
            if ex = entry.exception
              json.field "error", LogSanitizer.sanitize(ex.message || "")
            end
          end
        end
        @io << '\n'
        @io.flush
      end
    end

    # Tracks cumulative token usage across LLM calls.
    #
    # Thread-safe via Mutex. Call `record` after each LLM response
    # and `summary` to get a human-readable overview.
    class TokenTracker
      Log = ::Log.for("tokens")

      getter total_prompt_tokens : Int64 = 0
      getter total_completion_tokens : Int64 = 0
      getter total_requests : Int32 = 0

      @mutex : Mutex = Mutex.new

      # Record token usage from a single LLM response.
      def record(prompt_tokens : Int32, completion_tokens : Int32, model : String = "") : Nil
        @mutex.synchronize do
          @total_prompt_tokens += prompt_tokens
          @total_completion_tokens += completion_tokens
          @total_requests += 1
        end

        total = prompt_tokens + completion_tokens
        Log.info {
          String.build do |line|
            line << "req=#" << @total_requests
            line << " prompt=" << prompt_tokens
            line << " completion=" << completion_tokens
            line << " total=" << total
            line << " model=" << model unless model.empty?
            line << " | session: " << self.total_tokens << " tokens"
          end
        }
      end

      # Total tokens used across all requests.
      def total_tokens : Int64
        total_prompt_tokens + total_completion_tokens
      end

      # Human-readable summary.
      def summary : String
        "#{total_requests} requests, #{total_prompt_tokens} prompt + #{total_completion_tokens} completion = #{total_tokens} total tokens"
      end

      def reset : Nil
        @mutex.synchronize do
          @total_prompt_tokens = 0
          @total_completion_tokens = 0
          @total_requests = 0
        end
      end
    end

    # Tracks file operations performed by the agent for visibility.
    class FileTracker
      Log = ::Log.for("files")

      @operations : Array(FileOp) = [] of FileOp
      @mutex : Mutex = Mutex.new

      # Record a file operation.
      def record(action : String, path : String, bytes : Int64 = 0) : Nil
        @mutex.synchronize do
          @operations << FileOp.new(action, path, bytes)
        end
        Log.debug { "#{action}: #{path}#{bytes > 0 ? " (#{bytes} bytes)" : ""}" }
      end

      # List unique file paths touched.
      def touched_files : Array(String)
        @mutex.synchronize { @operations.map(&.path).uniq! }
      end

      # Human-readable summary grouped by action.
      def summary : String
        counts = {} of String => Int32
        total = 0
        @mutex.synchronize do
          total = @operations.size
          @operations.each do |op|
            counts[op.action] = (counts[op.action]? || 0) + 1
          end
        end
        parts = counts.map { |action, count| "#{action}=#{count}" }
        "#{total} file ops (#{parts.join(", ")})"
      end

      def reset : Nil
        @mutex.synchronize { @operations.clear }
      end

      private struct FileOp
        getter action : String
        getter path : String
        getter bytes : Int64

        def initialize(@action, @path, @bytes = 0_i64)
        end
      end
    end
  end
end
