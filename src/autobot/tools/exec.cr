require "log"
require "../constants"
require "./sandbox"

module Autobot
  module Tools
    # Tool to execute shell commands with safety guards.
    class ExecTool < Tool
      Log = ::Log.for(self)

      DEFAULT_TIMEOUT     =     60
      MAX_OUTPUT_SIZE     = 10_000
      SIGNAL_GRACE_PERIOD = 0.5.seconds

      # Deny patterns for dangerous operations (defense-in-depth)
      DEFAULT_DENY_PATTERNS = [
        # Link operations (symlinks and hardlinks can escape workspace)
        /\bln\s+/i,           # ln command (symlinks and hardlinks)
        /\bcp\s+.*-[a-z]*l/i, # cp with -l flag (hardlinks)
        /\bcp\s+--link/i,     # cp --link (hardlinks)

        # Destructive file operations
        /\brm\s+-[rf]{1,2}\b/i, # rm -r, rm -rf, rm -fr
        /\brm\s+-r\s+-f\b/i,    # rm -r -f (spaces between flags)
        /\bdel\s+\/[fq]\b/i,    # del /f, del /q
        /\brmdir\s+\/s\b/i,     # rmdir /s

        # Disk operations
        /\b(format|mkfs|diskpart)\b/i, # disk formatting
        /\bdd\s+if=/i,                 # dd
        />\s*\/dev\/sd/,               # write to disk device

        # System control
        /\b(shutdown|reboot|poweroff|halt|init\s+0)\b/i,

        # Fork bombs and resource exhaustion
        /:\(\)\s*\{.*\};\s*:/, # bash fork bomb
        /\bwhile\s+true\b/i,   # infinite loops

        # Remote code execution
        /\|\s*(bash|sh|zsh|fish|csh)\b/i,   # piped to shell
        /\bcurl\s+.*\|\s*(bash|sh)/i,       # curl | bash
        /\bwget\s+.*\|\s*(bash|sh)/i,       # wget | sh
        /\b(curl|wget)\s+.*-O.*\|\s*sh\b/i, # download and execute

        # Code execution
        /\bpython\s+-c\b/i, # python -c 'code'
        /\bperl\s+-e\b/i,   # perl -e 'code'
        /\bruby\s+-e\b/i,   # ruby -e 'code'
        /\bnode\s+-e\b/i,   # node -e 'code'
        /\beval\s+/i,       # eval command
        /\bexec\s+/i,       # exec command

        # Network tools (potential for reverse shells)
        /\b(nc|ncat|netcat)\s+/i, # netcat
        /\bsocat\s+/i,            # socat

        # Privilege escalation
        /\bsudo\s+/i,          # sudo
        /\bsu\s+/i,            # su (when not part of other commands)
        /\bchmod\s+[+]?[xs]/i, # chmod +x, chmod +s (setuid)
        /\bchown\s+root\b/i,   # chown root

        # System modification
        /\bcrontab\s+/i,   # cron job modification
        />\s*\/etc\//,     # write to /etc
        /\bsystemctl\s+/i, # systemd control

        # Process injection/debugging
        /\bgdb\s+/i,    # debugger
        /\bstrace\s+/i, # system call tracer
        /\bltrace\s+/i, # library call tracer
      ]

      # Shell feature patterns (for restricted mode without full_shell_access)
      OUTPUT_REDIRECT_PATTERN = />\s*\S/
      INPUT_REDIRECT_PATTERN  = /<\s*\S/
      DIR_CHANGE_PATTERN      = /\b(cd|chdir|pushd|popd)\b/

      getter timeout : Int32
      getter working_dir : String?
      getter deny_patterns : Array(Regex)
      getter allow_patterns : Array(Regex)
      getter? full_shell_access : Bool
      getter sandbox_type : Sandbox::Type

      def initialize(
        @executor : SandboxExecutor,
        @timeout = DEFAULT_TIMEOUT,
        @working_dir : String? = nil,
        @deny_patterns = DEFAULT_DENY_PATTERNS,
        @allow_patterns = [] of Regex,
        @full_shell_access = false,
        sandbox_config : String = "auto",
      )
        validate_config!(sandbox_config)
        @sandbox_type = resolve_sandbox_type(sandbox_config)
        ensure_sandbox_available!
      end

      def name : String
        "exec"
      end

      def description : String
        "Execute a shell command and return its output. Use with caution."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "command"     => PropertySchema.new(type: "string", description: "The shell command to execute"),
            "working_dir" => PropertySchema.new(type: "string", description: "Optional working directory for the command"),
          },
          required: ["command"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        command = params["command"].as_s
        user_cwd = params["working_dir"]?.try(&.as_s)

        Log.debug { "ExecTool: sandbox=#{@sandbox_type}, working_dir=#{@working_dir.inspect}" }

        cwd = user_cwd || @working_dir || Dir.current

        # Validate working directory is within workspace when sandboxed
        if sandboxed? && user_cwd
          if error = validate_working_dir(user_cwd)
            return ToolResult.access_denied(error)
          end
        end

        if error = guard_command(command)
          return ToolResult.access_denied(error)
        end

        Log.info { "Executing: #{command} (cwd: #{cwd}, sandbox: #{@sandbox_type})" }

        output = run_command(command, cwd)
        ToolResult.success(output)
      rescue ex
        ToolResult.error("Error executing command: #{ex.message}")
      end

      private def run_command(command : String, cwd : String) : String
        workspace = @working_dir

        if sandboxed? && workspace
          relative_cwd = calculate_relative_path(cwd, workspace)

          sandboxed_command = if relative_cwd == "." || relative_cwd.empty?
                                command
                              else
                                "cd #{Sandbox.shell_escape(relative_cwd)} && #{command}"
                              end

          result = @executor.exec(sandboxed_command, timeout: @timeout)
          result.success? ? result.content : "Error: #{result.content}"
        else
          run_command_direct(command, cwd)
        end
      end

      private def run_command_direct(command : String, cwd : String) : String
        # Use pipes to prevent unbounded memory allocation
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe

        process = Process.new(
          "sh", ["-c", command],
          output: stdout_write,
          error: stderr_write,
          chdir: cwd,
        )

        # Close write ends in parent process
        stdout_write.close
        stderr_write.close

        # Read output with size limits to prevent DoS
        stdout_channel = Channel(String).new(1)
        stderr_channel = Channel(String).new(1)

        spawn { stdout_channel.send(read_limited_output(stdout_read, MAX_OUTPUT_SIZE)) }
        spawn { stderr_channel.send(read_limited_output(stderr_read, MAX_OUTPUT_SIZE)) }

        completed = Channel(Process::Status).new(1)
        spawn do
          status = process.wait
          completed.send(status)
        end

        timed_out, status = wait_for_process(process, completed)

        # Collect limited outputs
        stdout_text = stdout_channel.receive
        stderr_text = stderr_channel.receive

        stdout_read.close
        stderr_read.close

        build_command_result(stdout_text, stderr_text, status, timed_out)
      end

      private def read_limited_output(io : IO, max_size : Int32) : String
        buffer = IO::Memory.new
        bytes_read = 0
        chunk = Bytes.new(4096)

        while (n = io.read(chunk)) > 0
          bytes_read += n
          if bytes_read > max_size
            buffer.write(chunk[0, Math.max(0, max_size - (bytes_read - n))])
            buffer << "\n... (output truncated at #{max_size} bytes)"
            break
          end
          buffer.write(chunk[0, n])
        end

        buffer.to_s
      rescue
        ""
      end

      private def build_command_result(stdout_text : String, stderr_text : String, status : Process::Status?, timed_out : Bool) : String
        parts = [] of String

        if timed_out
          parts << "Error: Command timed out after #{@timeout} seconds"
        end

        parts << stdout_text unless stdout_text.empty?

        if !stderr_text.empty? && stderr_text.strip.size > 0
          parts << "STDERR:\n#{stderr_text}"
        end

        if status && !status.success? && !timed_out
          parts << "\nExit code: #{status.exit_code}"
        end

        parts.empty? ? Constants::NO_OUTPUT_MESSAGE : parts.join("\n")
      end

      private def wait_for_process(process : Process, completed : Channel(Process::Status)) : {Bool, Process::Status?}
        select
        when status = completed.receive
          {false, status}
        when timeout(@timeout.seconds)
          begin
            process.signal(Signal::TERM)
            sleep SIGNAL_GRACE_PERIOD
            process.signal(Signal::KILL) unless process.terminated?
            process.wait
          rescue
            # Process already terminated
          end
          {true, nil}
        end
      end

      private def guard_command(command : String) : String?
        cmd = command.strip

        @deny_patterns.each do |pattern|
          if pattern.matches?(cmd)
            return "Error: Command blocked by safety guard (dangerous pattern detected)"
          end
        end

        unless @allow_patterns.empty?
          unless @allow_patterns.any?(&.matches?(cmd))
            return "Error: Command blocked by safety guard (not in allowlist)"
          end
        end

        if sandboxed?
          # Block cd commands entirely - they change execution context
          if cmd.match(DIR_CHANGE_PATTERN)
            return "Error: Directory change commands are blocked when sandboxed"
          end

          # Always block shell expansion when sandboxed
          # Variables can be used to construct paths and commands dynamically
          if error = check_shell_expansion(cmd)
            return error
          end

          # Block shell features when full_shell_access is disabled (secure default)
          unless @full_shell_access
            if error = check_shell_features(cmd)
              return error
            end
          end
        end

        nil
      end

      private def check_shell_expansion(command : String) : String?
        # Block dangerous shell expansion that could bypass sandbox
        return "Error: Shell expansion detected - $HOME not allowed" if command.includes?("$HOME")
        return "Error: Shell expansion detected - ${} not allowed" if command.includes?("${")
        return "Error: Shell expansion detected - $USER not allowed" if command.includes?("$USER")
        return "Error: Shell expansion detected - $PATH not allowed" if command.includes?("$PATH")
        return "Error: Shell expansion detected - backticks not allowed" if command.includes?("`")
        return "Error: Shell expansion detected - $() not allowed" if command.includes?("$(")

        # Block ALL variables when workspace restricted (they can bypass validation)
        return "Error: Shell variables not allowed in restricted mode" if command.includes?("$")
        nil
      end

      private def check_shell_features(command : String) : String?
        return "Error: Pipes not allowed in restricted mode (use direct commands)" if command.includes?("|")
        return "Error: Output redirection not allowed in restricted mode" if command.match(OUTPUT_REDIRECT_PATTERN)
        return "Error: Input redirection not allowed in restricted mode" if command.match(INPUT_REDIRECT_PATTERN)
        return "Error: Command chaining not allowed in restricted mode (use one command)" if command.includes?(";") || command.includes?("&&") || command.includes?("||")
        return "Error: Background execution not allowed in restricted mode" if command.includes?("&")
        nil
      end

      private def validate_config!(sandbox_config : String) : Nil
        # Check for mutually exclusive settings based on CONFIG, not detected availability
        sandbox_requested = sandbox_config.downcase != "none"

        if sandbox_requested && @full_shell_access
          raise ArgumentError.new(
            "Invalid configuration: sandbox and full_shell_access are mutually exclusive. " \
            "Sandboxing requires simple commands (no shell features). " \
            "For full shell access (pipes, redirects), use sandbox: none."
          )
        end
      end

      private def resolve_sandbox_type(sandbox_config : String) : Sandbox::Type
        Sandbox.resolve_type(sandbox_config)
      end

      private def ensure_sandbox_available! : Nil
        # When sandbox is required (not none), verify it's actually available
        if sandboxed? && @sandbox_type == Sandbox::Type::None
          Sandbox.require_sandbox!
        end
      end

      def sandboxed? : Bool
        @sandbox_type != Sandbox::Type::None
      end

      private def calculate_relative_path(cwd : String, workspace : String) : String
        if cwd.starts_with?(workspace)
          cwd[workspace.size..-1].lstrip('/')
        else
          "."
        end
      end

      private def validate_working_dir(user_cwd : String) : String?
        working_dir = @working_dir
        return nil unless working_dir

        workspace_real = begin
          File.realpath(working_dir)
        rescue
          return "Error: Cannot resolve workspace path"
        end

        cwd_real = begin
          File.realpath(user_cwd)
        rescue
          return "Error: Cannot resolve working directory path"
        end

        unless cwd_real.starts_with?(workspace_real + "/") || cwd_real == workspace_real
          return "SECURITY_ERROR: Working directory '#{user_cwd}' is outside workspace. Access denied."
        end

        nil
      end
    end
  end
end
