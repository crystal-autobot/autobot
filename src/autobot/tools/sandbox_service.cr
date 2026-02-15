require "json"
require "socket"
require "log"
require "./sandbox"

module Autobot
  module Tools
    # Persistent sandbox service for high-performance sandboxed operations (Linux only)
    # Requires bubblewrap and autobot-server binary
    # Communicates via Unix socket for 15x faster operations than Sandbox.exec
    class SandboxService
      Log = ::Log.for(self)

      # Connection timeout constants
      SOCKET_CONNECTION_MAX_ATTEMPTS = 50
      SOCKET_CHECK_INTERVAL          = 0.1.seconds
      SIGNAL_GRACE_PERIOD            = 0.5.seconds
      MAX_RECOVERY_ATTEMPTS          = 2
      RECOVERY_BACKOFF               = 0.5.seconds

      # Operation types supported by the sandbox service
      enum OperationType
        ReadFile
        WriteFile
        ListDir
        Exec
      end

      # Request sent to sandbox server
      struct Request
        include JSON::Serializable

        getter id : String
        getter op : String
        getter path : String?
        getter content : String?
        getter command : String?
        getter stdin : String?
        getter timeout : Int32?

        def initialize(
          @id : String,
          @op : String,
          @path : String? = nil,
          @content : String? = nil,
          @command : String? = nil,
          @stdin : String? = nil,
          @timeout : Int32? = nil,
        )
        end
      end

      # Response received from sandbox server
      struct Response
        include JSON::Serializable

        getter id : String
        getter status : String
        getter data : String?
        getter error : String?
        getter exit_code : Int32?

        def success? : Bool
          status == "ok"
        end
      end

      # Operation to execute in sandbox
      class Operation
        getter type : OperationType
        getter path : String?
        getter content : String?
        getter command : String?
        getter stdin : String?
        getter timeout : Int32?

        def initialize(
          @type : OperationType,
          @path : String? = nil,
          @content : String? = nil,
          @command : String? = nil,
          @stdin : String? = nil,
          @timeout : Int32? = nil,
        )
        end

        def to_request(id : String) : Request
          Request.new(
            id: id,
            op: type.to_s.underscore,
            path: @path,
            content: @content,
            command: @command,
            stdin: @stdin,
            timeout: @timeout
          )
        end
      end

      @workspace : Path
      @sandbox_type : Sandbox::Type
      @process : Process?
      @socket_path : String?
      @socket : UNIXSocket?
      @running : Bool = false
      @request_counter : Atomic(Int32) = Atomic(Int32).new(0)

      def initialize(@workspace : Path, @sandbox_type : Sandbox::Type)
        Log.debug { "SandboxService initialized: workspace=#{@workspace}, type=#{@sandbox_type}" }
      end

      # Start the persistent sandbox service (Linux/bubblewrap only)
      def start : Nil
        raise "SandboxService already running" if @running
        raise "SandboxService only supports bubblewrap (Linux only)" unless @sandbox_type == Sandbox::Type::Bubblewrap

        socket_path = create_socket_path
        @socket_path = socket_path
        Log.info { "Starting sandbox service at #{socket_path}" }

        start_bubblewrap(socket_path)

        @running = true
        connect_to_service
      end

      # Stop the persistent sandbox service
      def stop : Nil
        return unless @running

        Log.info { "Stopping sandbox service" }

        if socket = @socket
          socket.close rescue nil
        end

        if process = @process
          begin
            process.signal(Signal::TERM)
            sleep SIGNAL_GRACE_PERIOD
            process.signal(Signal::KILL) unless process.terminated?
            process.wait
          rescue
            # Process already terminated
          end
        end

        if socket_path = @socket_path
          File.delete(socket_path) if File.exists?(socket_path)
        end

        @running = false
        @process = nil
        @socket = nil
        @socket_path = nil
      end

      # Execute a single operation in the sandbox with automatic recovery
      def execute(operation : Operation) : Response
        raise "SandboxService not running" unless @running

        attempt = 0
        last_error : Exception? = nil

        loop do
          begin
            request_id = next_request_id
            request = operation.to_request(request_id)

            send_request(request)
            return receive_response(request_id)
          rescue ex : IO::Error
            # Socket/IPC error - service likely crashed
            last_error = ex
            attempt += 1

            if attempt <= MAX_RECOVERY_ATTEMPTS && service_recoverable?
              Log.warn { "Sandbox service communication failed (attempt #{attempt}/#{MAX_RECOVERY_ATTEMPTS}): #{ex.message}" }
              Log.info { "Attempting to recover sandbox service..." }

              begin
                recover_service
                sleep RECOVERY_BACKOFF
                # Loop will retry operation
              rescue ex
                Log.error { "Failed to recover sandbox service: #{ex.message}" }
                raise "Sandbox service crashed and recovery failed: #{ex.message}"
              end
            else
              raise "Sandbox service crashed after #{attempt} attempts: #{last_error.try(&.message)}"
            end
          end
        end
      end

      # Execute multiple operations in batch (not implemented yet, returns sequential)
      def batch(operations : Array(Operation)) : Array(Response)
        operations.map { |op| execute(op) }
      end

      # Check if service is running
      def running? : Bool
        @running
      end

      # Check if the service can be recovered (process exists and hasn't terminated)
      private def service_recoverable? : Bool
        # Check if process is still alive
        if process = @process
          return false if process.terminated?
        end
        true
      end

      # Attempt to recover the sandbox service by restarting it
      private def recover_service : Nil
        Log.info { "Stopping crashed sandbox service..." }
        cleanup_crashed_service
        restart_service
        Log.info { "Sandbox service recovered successfully" }
      end

      # Clean up resources from a crashed service
      private def cleanup_crashed_service : Nil
        if socket = @socket
          socket.close rescue nil
        end

        if process = @process
          begin
            process.signal(Signal::TERM)
            sleep SIGNAL_GRACE_PERIOD
            process.signal(Signal::KILL) unless process.terminated?
            process.wait
          rescue
            # Process already dead
          end
        end

        if socket_path = @socket_path
          File.delete(socket_path) if File.exists?(socket_path)
        end

        @socket = nil
        @process = nil
        @running = false
      end

      # Restart the service with a fresh socket
      private def restart_service : Nil
        Log.info { "Restarting sandbox service..." }
        socket_path = create_socket_path
        @socket_path = socket_path

        start_bubblewrap(socket_path)

        @running = true
        connect_to_service
      end

      private def create_socket_path : String
        "/tmp/autobot-sandbox-#{Process.pid}.sock"
      end

      private def next_request_id : String
        count = @request_counter.add(1)
        "req-#{count}"
      end

      private def start_bubblewrap(socket_path : String) : Nil
        workspace_real = File.realpath(@workspace.to_s)

        bwrap_args = [
          "--ro-bind", "/usr", "/usr",
          "--ro-bind", "/lib", "/lib",
          "--ro-bind", "/lib64", "/lib64",
          "--ro-bind", "/bin", "/bin",
          "--ro-bind", "/sbin", "/sbin",
          "--bind", workspace_real, workspace_real,
          "--bind", "/tmp", "/tmp",
          "--proc", "/proc",
          "--dev", "/dev",
          "--unshare-all",
          "--share-net",
          "--die-with-parent",
          "--chdir", workspace_real,
          "--", "autobot-server", socket_path, workspace_real,
        ]

        Log.debug { "Starting bubblewrap with autobot-server" }
        @process = Process.new("bwrap", bwrap_args)
      end

      private def connect_to_service : Nil
        socket_path = @socket_path || raise "Socket path not set"

        # Wait for socket to be created
        attempt = 0
        while !File.exists?(socket_path) && attempt < SOCKET_CONNECTION_MAX_ATTEMPTS
          sleep SOCKET_CHECK_INTERVAL
          attempt += 1
        end

        raise "Sandbox service socket not created: #{socket_path}" unless File.exists?(socket_path)

        # Connect to socket
        @socket = UNIXSocket.new(socket_path)
        Log.debug { "Connected to sandbox service" }
      end

      private def send_request(request : Request) : Nil
        socket = @socket || raise "Socket not connected"
        json = request.to_json
        socket.puts(json)
        socket.flush
      end

      private def receive_response(request_id : String) : Response
        socket = @socket || raise "Socket not connected"

        # Read response line
        line = socket.gets
        raise "No response from sandbox service" unless line

        response = Response.from_json(line)

        # Verify response matches request
        if response.id != request_id
          raise "Response ID mismatch: expected #{request_id}, got #{response.id}"
        end

        response
      end
    end
  end
end
