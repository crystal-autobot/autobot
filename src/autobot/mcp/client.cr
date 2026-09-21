require "json"
require "log"

module Autobot
  module Mcp
    # JSON-RPC 2.0 client that communicates with an MCP server over stdio.
    #
    # Spawns a child process, performs the MCP protocol handshake,
    # and provides methods to discover and call remote tools.
    # All requests are serialized through a mutex (stdio is single-threaded).
    #
    # Env isolation: only configured env vars + PATH/HOME/LANG are passed.
    # Stderr is drained in a background fiber to prevent the child from blocking.
    class Client
      Log = ::Log.for("mcp.client")

      PROTOCOL_VERSION  = "2025-03-26"
      INIT_TIMEOUT      = 30.seconds
      CALL_TIMEOUT      = 60.seconds
      SHUTDOWN_GRACE    = 2.seconds
      MAX_RESPONSE_SIZE = 50_000
      ALLOWED_HOST_VARS = {"PATH", "HOME", "LANG"}

      # A tools/call outcome. MCP reports a failing tool as a normal response
      # carrying `isError`, so the flag has to travel with the content.
      record CallResult, content : String, failed : Bool do
        def success? : Bool
          !failed
        end
      end

      getter server_name : String

      @process : Process?
      @stdin : IO?
      @stdout : IO?
      @responses : Channel(JSON::Any)?
      @mutex : Mutex
      @request_id : Int64

      def initialize(
        @server_name : String,
        @command : String,
        @args : Array(String) = [] of String,
        @env : Hash(String, String) = {} of String => String,
        @call_timeout : Time::Span = CALL_TIMEOUT,
      )
        @mutex = Mutex.new
        @request_id = 0_i64
      end

      # Spawns the MCP server process and performs the protocol handshake.
      # Raises on failure (e.g. command not found, handshake timeout).
      def start : Nil
        env = build_env
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe
        stdin_read, stdin_write = IO.pipe

        process = Process.new(
          @command, @args,
          input: stdin_read,
          output: stdout_write,
          error: stderr_write,
          env: env,
          clear_env: true,
        )

        # Close child-side ends in parent
        stdin_read.close
        stdout_write.close
        stderr_write.close

        @process = process
        @stdin = stdin_write
        @stdout = stdout_read

        drain_stderr(stderr_read)
        start_reader(stdout_read)

        begin
          perform_initialize
        rescue ex
          stop
          raise ex
        end

        Log.info { "[#{@server_name}] MCP server started (pid=#{process.pid})" }
      end

      # Gracefully stops the MCP server: SIGTERM, wait, then SIGKILL if needed.
      def stop : Nil
        process = @process
        return unless process

        begin
          process.signal(Signal::TERM)
          wait_for_termination(process)
          process.signal(Signal::KILL) unless process.terminated?
          process.wait
        rescue
          # Already terminated
        end

        @stdin.try(&.close) rescue nil
        @stdout.try(&.close) rescue nil
        @responses.try(&.close) rescue nil
        @responses = nil
        @process = nil
        Log.info { "[#{@server_name}] MCP server stopped" }
      end

      def alive? : Bool
        process = @process
        return false unless process
        !process.terminated?
      end

      # Sends `tools/list` to the server and returns the tool definitions.
      def list_tools : Array(JSON::Any)
        response = send_request("tools/list", JSON::Any.new({} of String => JSON::Any))
        result = response["result"]?
        return [] of JSON::Any unless result

        result["tools"]?.try(&.as_a?) || [] of JSON::Any
      end

      # Calls a tool on the MCP server and returns the text content.
      # Result is truncated at `MAX_RESPONSE_SIZE` bytes.
      def call_tool(
        name : String,
        arguments : Hash(String, JSON::Any),
        timeout : Time::Span = @call_timeout,
      ) : CallResult
        params = {
          "name"      => JSON::Any.new(name),
          "arguments" => JSON::Any.new(arguments),
        }
        response = send_request("tools/call", JSON::Any.new(params), timeout: timeout)

        if error = response["error"]?
          message = error["message"]?.try(&.as_s?) || "Unknown MCP error"
          return CallResult.new("Error: #{message}", failed: true)
        end

        CallResult.new(extract_content(response), failed: tool_failed?(response))
      end

      private def tool_failed?(response : JSON::Any) : Bool
        response["result"]?.try(&.["isError"]?).try(&.as_bool?) || false
      end

      private def wait_for_termination(process : Process) : Nil
        elapsed = Time::Span.zero
        poll_interval = 50.milliseconds

        while elapsed < SHUTDOWN_GRACE
          return if process.terminated?
          sleep poll_interval
          elapsed += poll_interval
        end
      end

      private def perform_initialize : Nil
        params = {
          "protocolVersion" => JSON::Any.new(PROTOCOL_VERSION),
          "capabilities"    => JSON::Any.new({} of String => JSON::Any),
          "clientInfo"      => JSON::Any.new({
            "name"    => JSON::Any.new("autobot"),
            "version" => JSON::Any.new(Autobot::VERSION),
          }),
        }

        send_request("initialize", JSON::Any.new(params), timeout: INIT_TIMEOUT)
        send_notification("notifications/initialized", JSON::Any.new({} of String => JSON::Any))
      end

      private def send_request(method : String, params : JSON::Any, timeout : Time::Span = CALL_TIMEOUT) : JSON::Any
        @mutex.synchronize do
          @request_id += 1
          id = @request_id

          request = {
            "jsonrpc" => JSON::Any.new("2.0"),
            "id"      => JSON::Any.new(id),
            "method"  => JSON::Any.new(method),
            "params"  => params,
          }

          write_message(JSON::Any.new(request))
          read_response(id, timeout)
        end
      end

      private def send_notification(method : String, params : JSON::Any) : Nil
        @mutex.synchronize do
          message = {
            "jsonrpc" => JSON::Any.new("2.0"),
            "method"  => JSON::Any.new(method),
            "params"  => params,
          }
          write_message(JSON::Any.new(message))
        end
      end

      private def write_message(message : JSON::Any) : Nil
        stdin = @stdin
        raise "MCP server not running" unless stdin

        data = message.to_json
        stdin.print(data + "\n")
        stdin.flush
      end

      private def start_reader(stdout : IO) : Nil
        responses = Channel(JSON::Any).new
        @responses = responses

        spawn(name: "mcp-reader-#{@server_name}") do
          begin
            while line = stdout.gets
              line = line.strip
              next if line.empty?

              parsed = begin
                JSON.parse(line)
              rescue JSON::ParseException
                next
              end

              # Skip server notifications (messages without id or with method)
              next unless parsed["id"]? && parsed["method"]?.nil?

              responses.send(parsed)
            end
          rescue IO::Error | Channel::ClosedError
            # Stream or channel closed during shutdown
          ensure
            responses.close rescue nil
          end
        end
      end

      private def read_response(expected_id : Int64, timeout : Time::Span) : JSON::Any
        responses = @responses
        raise "MCP server not running" unless responses

        deadline = Time.instant + timeout
        loop do
          remaining = {Time::Span.zero, deadline - Time.instant}.max
          select
          when response = responses.receive?
            raise "MCP server closed the connection" unless response
            return response if response["id"]?.try(&.as_i64?) == expected_id
          when timeout(remaining)
            raise "MCP request timed out after #{timeout.total_seconds.to_i}s"
          end
        end
      end

      private def extract_content(response : JSON::Any) : String
        result = response["result"]?
        return "No result" unless result

        content = result["content"]?
        return result.to_json unless content

        parts = content.as_a?.try(&.compact_map { |item|
          item["text"]?.try(&.as_s?)
        }) || [] of String

        text = parts.join("\n")
        truncate(text, MAX_RESPONSE_SIZE)
      end

      private def truncate(text : String, max : Int32) : String
        return text if text.bytesize <= max
        text.byte_slice(0, max) + "\n... (truncated at #{max} bytes)"
      end

      private def build_env : Hash(String, String)
        env = {} of String => String
        ALLOWED_HOST_VARS.each do |var|
          if value = ENV[var]?
            env[var] = value
          end
        end
        @env.each { |k, v| env[k] = v }
        env
      end

      private def drain_stderr(stderr : IO) : Nil
        spawn(name: "mcp-stderr-#{@server_name}") do
          begin
            while line = stderr.gets
              Log.debug { "[#{@server_name}] stderr: #{line}" }
            end
          rescue
            # Stream closed
          ensure
            stderr.close rescue nil
          end
        end
      end
    end
  end
end
