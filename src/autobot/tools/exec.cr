require "log"
require "../constants"

module Autobot
  module Tools
    # Tool to execute shell commands with safety guards.
    class ExecTool < Tool
      Log = ::Log.for(self)

      DEFAULT_TIMEOUT     =     60
      MAX_OUTPUT_SIZE     = 10_000
      SIGNAL_GRACE_PERIOD = 0.5.seconds

      # Path validation patterns
      DIR_CHANGE_PATTERN          = /\b(cd|chdir|pushd|popd)\b/
      BARE_DOTDOT_PATTERN         = /(?:^|[\s|>&<;])\.\.(?:[\s|>&<;]|$)/
      UNQUOTED_TILDE_PATTERN      = /(?:^|[\s|>])~/
      UNQUOTED_ABSOLUTE_PATH      = /(?:^|[\s|><&;])([~\/][^\s"'|>&<;]+)/
      DOUBLE_QUOTED_ABSOLUTE_PATH = /"([~\/][^"]+)"/
      SINGLE_QUOTED_ABSOLUTE_PATH = /'([~\/][^']+)'/
      UNQUOTED_RELATIVE_PATH      = /(?:^|[\s|>])([^\s"'|>&]*\.\.\/[^\s"'|>&]*)/
      DOUBLE_QUOTED_RELATIVE_PATH = /"([^"]*\.\.\/[^"]*)"/
      SINGLE_QUOTED_RELATIVE_PATH = /'([^']*\.\.\/[^']*)'/

      # Shell feature patterns (for restricted mode without full_shell_access)
      OUTPUT_REDIRECT_PATTERN     = />\s*\S/
      INPUT_REDIRECT_PATTERN      = /<\s*\S/
      VARIABLE_ASSIGNMENT_PATTERN = /[A-Z_]\w*=/

      DEFAULT_DENY_PATTERNS = [
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

      getter timeout : Int32
      getter working_dir : String?
      getter deny_patterns : Array(Regex)
      getter allow_patterns : Array(Regex)
      getter? restrict_to_workspace : Bool
      getter? full_shell_access : Bool

      def initialize(
        @timeout = DEFAULT_TIMEOUT,
        @working_dir : String? = nil,
        @deny_patterns = DEFAULT_DENY_PATTERNS,
        @allow_patterns = [] of Regex,
        @restrict_to_workspace = false,
        @full_shell_access = false,
      )
        # Validate incompatible security settings
        if @restrict_to_workspace && @full_shell_access
          raise ArgumentError.new(
            "Invalid configuration: restrict_to_workspace and full_shell_access are mutually exclusive. " \
            "Workspace restrictions require simple commands (no shell features). " \
            "For full shell access (pipes, redirects), disable workspace restrictions."
          )
        end
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

        Log.debug { "ExecTool: restrict=#{@restrict_to_workspace}, working_dir=#{@working_dir.inspect}" }

        # Validate working directory when workspace restrictions are enabled
        if @restrict_to_workspace && user_cwd
          if error = validate_working_dir(user_cwd)
            return ToolResult.access_denied(error)
          end
        end

        cwd = user_cwd || @working_dir || Dir.current

        if error = guard_command(command, cwd)
          return ToolResult.access_denied(error)
        end

        Log.info { "Executing: #{command} (cwd: #{cwd})" }

        output = run_command(command, cwd)
        ToolResult.success(output)
      rescue ex
        ToolResult.error("Error executing command: #{ex.message}")
      end

      private def run_command(command : String, cwd : String) : String
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

      private def guard_command(command : String, cwd : String) : String?
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

        if @restrict_to_workspace
          # Block cd commands entirely - they change execution context
          if error = check_directory_change(cmd)
            return error
          end

          # Block shell features when full_shell_access is disabled (secure default)
          unless @full_shell_access
            if error = check_shell_features(cmd)
              return error
            end
          end

          if error = check_path_traversal(cmd, cwd)
            return error
          end
        end

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

      private def validate_working_dir(user_cwd : String) : String?
        working_dir = @working_dir
        return nil unless working_dir

        workspace_real = resolve_workspace_path(working_dir)
        return workspace_real if workspace_real.starts_with?("Error:")

        cwd_real = resolve_workspace_path(user_cwd)
        return cwd_real if cwd_real.starts_with?("Error:")

        unless cwd_real.starts_with?(workspace_real + "/") || cwd_real == workspace_real
          return "SECURITY_ERROR: Working directory '#{user_cwd}' is outside workspace. Access denied."
        end

        nil
      end

      private def check_directory_change(command : String) : String?
        if command.match(DIR_CHANGE_PATTERN)
          return "Error: Directory change commands are blocked when workspace restrictions are enabled"
        end
        nil
      end

      private def check_path_traversal(command : String, cwd : String) : String?
        workspace_real = resolve_workspace_path(cwd)
        return workspace_real if workspace_real.starts_with?("Error:")

        # Check for basic traversal patterns first
        if has_traversal_pattern?(command)
          return "SECURITY_ERROR: Path traversal detected - ../ sequences are blocked"
        end

        if has_encoded_traversal?(command)
          return "SECURITY_ERROR: Encoded path traversal detected"
        end

        # Check shell expansion (but allow ~ in quoted strings as those are validated separately)
        if has_unquoted_shell_expansion?(command)
          return "SECURITY_ERROR: Shell expansion detected - use literal paths only"
        end

        validate_command_paths(command, workspace_real)
      end

      private def resolve_workspace_path(cwd : String) : String
        File.realpath(cwd)
      rescue
        "Error: Cannot resolve workspace path"
      end

      private def has_traversal_pattern?(command : String) : Bool
        return true if command.includes?("../")
        return true if command.includes?("..\\")
        return true if command.match(BARE_DOTDOT_PATTERN)
        false
      end

      private def has_encoded_traversal?(command : String) : Bool
        command.includes?("%2e%2e") || command.includes?("%2E%2E")
      end

      private def has_unquoted_shell_expansion?(command : String) : Bool
        # Always block these dangerous patterns
        return true if command.includes?("$HOME")
        return true if command.includes?("${")
        return true if command.includes?("$USER")
        return true if command.includes?("$PATH")
        return true if command.includes?("`")
        return true if command.includes?("$(")
        return true if command.match(UNQUOTED_TILDE_PATTERN)

        # When workspace restricted, ALWAYS block variables (they bypass path validation)
        # full_shell_access only controls pipes/redirects, NOT variables
        return true if command.includes?("$")
        return true if command.match(VARIABLE_ASSIGNMENT_PATTERN)

        false
      end

      private def validate_command_paths(command : String, workspace_real : String) : String?
        # Check unquoted absolute/home paths
        command.scan(UNQUOTED_ABSOLUTE_PATH) do |match|
          path_str = match[1].strip
          if error = validate_single_path(path_str, workspace_real)
            return error
          end
        end

        # Check double-quoted absolute/home paths
        command.scan(DOUBLE_QUOTED_ABSOLUTE_PATH) do |match|
          path_str = match[1].strip
          if error = validate_single_path(path_str, workspace_real)
            return error
          end
        end

        # Check single-quoted absolute/home paths
        command.scan(SINGLE_QUOTED_ABSOLUTE_PATH) do |match|
          path_str = match[1].strip
          if error = validate_single_path(path_str, workspace_real)
            return error
          end
        end

        # Check unquoted relative paths with ../
        command.scan(UNQUOTED_RELATIVE_PATH) do |match|
          path_str = match[1].strip
          next if path_str.empty?
          if error = validate_relative_path(path_str, workspace_real)
            return error
          end
        end

        # Check double-quoted relative paths
        command.scan(DOUBLE_QUOTED_RELATIVE_PATH) do |match|
          path_str = match[1].strip
          if error = validate_relative_path(path_str, workspace_real)
            return error
          end
        end

        # Check single-quoted relative paths
        command.scan(SINGLE_QUOTED_RELATIVE_PATH) do |match|
          path_str = match[1].strip
          if error = validate_relative_path(path_str, workspace_real)
            return error
          end
        end

        nil
      end

      private def validate_relative_path(path_str : String, workspace_real : String) : String?
        # Resolve relative path against workspace and validate
        full_path = File.join(workspace_real, path_str)
        real_path = resolve_real_path(full_path)

        unless real_path.starts_with?(workspace_real + "/") || real_path == workspace_real
          return "Error: Path '#{path_str}' resolves outside workspace"
        end

        nil
      rescue
        "Error: Cannot validate path '#{path_str}'"
      end

      private def validate_single_path(path_str : String, workspace_real : String) : String?
        expanded = Path[path_str].expand(home: true).to_s
        real_path = resolve_real_path(expanded)

        unless real_path.starts_with?(workspace_real + "/") || real_path == workspace_real
          return "SECURITY_ERROR: Access denied - path '#{path_str}' is outside workspace. Workspace restrictions are enabled. Only files within workspace are accessible."
        end

        nil
      rescue
        "SECURITY_ERROR: Cannot validate path '#{path_str}' - access denied for security"
      end

      private def resolve_real_path(expanded : String) : String
        if File.exists?(expanded) || Dir.exists?(expanded)
          File.realpath(expanded)
        else
          parent = File.dirname(expanded)
          if File.exists?(parent)
            real_parent = File.realpath(parent)
            File.join(real_parent, File.basename(expanded))
          else
            expanded
          end
        end
      end
    end
  end
end
