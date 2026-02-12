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

      def initialize(
        @timeout = DEFAULT_TIMEOUT,
        @working_dir : String? = nil,
        @deny_patterns = DEFAULT_DENY_PATTERNS,
        @allow_patterns = [] of Regex,
        @restrict_to_workspace = false,
      )
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

      def execute(params : Hash(String, JSON::Any)) : String
        command = params["command"].as_s
        cwd = params["working_dir"]?.try(&.as_s) || @working_dir || Dir.current

        if error = guard_command(command, cwd)
          return error
        end

        Log.info { "Executing: #{command} (cwd: #{cwd})" }

        run_command(command, cwd)
      rescue ex
        "Error executing command: #{ex.message}"
      end

      private def run_command(command : String, cwd : String) : String
        stdout = IO::Memory.new
        stderr = IO::Memory.new

        process = Process.new(
          "sh", ["-c", command],
          output: stdout,
          error: stderr,
          chdir: cwd,
        )

        completed = Channel(Process::Status).new(1)
        spawn do
          status = process.wait
          completed.send(status)
        end

        timed_out, status = wait_for_process(process, completed)

        parts = [] of String

        if timed_out
          parts << "Error: Command timed out after #{@timeout} seconds"
        end

        stdout_text = stdout.to_s
        parts << stdout_text unless stdout_text.empty?

        stderr_text = stderr.to_s
        if !stderr_text.empty? && stderr_text.strip.size > 0
          parts << "STDERR:\n#{stderr_text}"
        end

        if status && !status.success? && !timed_out
          parts << "\nExit code: #{status.exit_code}"
        end

        result = parts.empty? ? Constants::NO_OUTPUT_MESSAGE : parts.join("\n")

        if result.size > MAX_OUTPUT_SIZE
          result = result[0, MAX_OUTPUT_SIZE] + "\n... (truncated, #{result.size - MAX_OUTPUT_SIZE} more chars)"
        end

        result
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
          if error = check_path_traversal(cmd, cwd)
            return error
          end
        end

        nil
      end

      private def check_path_traversal(command : String, cwd : String) : String?
        workspace_real = resolve_workspace_path(cwd)
        return workspace_real if workspace_real.starts_with?("Error:")

        return "Error: Path traversal detected" if has_traversal_pattern?(command)
        return "Error: Encoded path traversal detected" if has_encoded_traversal?(command)
        return "Error: Shell expansion detected" if has_shell_expansion?(command)

        validate_command_paths(command, workspace_real)
      end

      private def resolve_workspace_path(cwd : String) : String
        File.realpath(cwd)
      rescue
        "Error: Cannot resolve workspace path"
      end

      private def has_traversal_pattern?(command : String) : Bool
        command.includes?("../") || command.includes?("..\\")
      end

      private def has_encoded_traversal?(command : String) : Bool
        command.includes?("%2e%2e") || command.includes?("%2E%2E")
      end

      private def has_shell_expansion?(command : String) : Bool
        command.includes?("$HOME") ||
          command.includes?("${") ||
          command.includes?("$USER") ||
          command.includes?("$PATH") ||
          command.includes?("~") ||
          command.includes?("`") ||
          command.includes?("$(")
      end

      private def validate_command_paths(command : String, workspace_real : String) : String?
        command.scan(/(?:^|[\s|>])([~\/][^\s"'|>&]+)/) do |match|
          path_str = match[1].strip
          if error = validate_single_path(path_str, workspace_real)
            return error
          end
        end
        nil
      end

      private def validate_single_path(path_str : String, workspace_real : String) : String?
        expanded = Path[path_str].expand(home: true).to_s
        real_path = resolve_real_path(expanded)

        unless real_path.starts_with?(workspace_real + "/") || real_path == workspace_real
          return "Error: Path '#{path_str}' resolves outside workspace"
        end

        nil
      rescue
        "Error: Cannot validate path '#{path_str}'"
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
