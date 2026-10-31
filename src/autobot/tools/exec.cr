require "log"
require "../config/env"
require "./sandbox_executor"

module Autobot
  module Tools
    # Tool to execute shell commands with safety guards.
    class ExecTool < Tool
      Log = ::Log.for(self)

      DEFAULT_TIMEOUT = 60

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

      getter timeout : Int32
      getter working_dir : String?
      getter deny_patterns : Array(Regex)
      getter allow_patterns : Array(Regex)

      def initialize(
        @executor : SandboxExecutor,
        @timeout = DEFAULT_TIMEOUT,
        @working_dir : String? = nil,
        @deny_patterns = DEFAULT_DENY_PATTERNS,
        @allow_patterns = [] of Regex,
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

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        command = params["command"].as_s
        if error = guard_command(command)
          return ToolResult.access_denied(error)
        end

        cwd = params["working_dir"]?.try(&.as_s) || @working_dir
        Log.info { "Executing: #{command} (cwd: #{cwd.inspect}, sandbox: #{@executor.mode})" }

        result = @executor.exec(command, timeout: @timeout, cwd: cwd)
        return result if result.success? || result.access_denied?

        ToolResult.error("Error: #{result.content}")
      rescue ex
        ToolResult.error("Error executing command: #{ex.message}")
      end

      private def guard_command(command : String) : String?
        cmd = command.strip
        has_allowlist = !@allow_patterns.empty?

        if Config::Env.command_references_file?(cmd)
          return "Error: Command blocked by safety guard (references an .env file)"
        end

        # 1. Check allowlist first (explicitly allowed overrides denylist)
        if has_allowlist && @allow_patterns.any?(&.matches?(cmd))
          return nil
        end

        # 2. Check denylist
        @deny_patterns.each do |pattern|
          if pattern.matches?(cmd)
            return "Error: Command blocked by safety guard (dangerous pattern detected)"
          end
        end

        # 3. If an allowlist exists but didn't match, block it
        if has_allowlist
          return "Error: Command blocked by safety guard (not in allowlist)"
        end

        nil
      end
    end
  end
end
