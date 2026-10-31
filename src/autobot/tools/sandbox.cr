require "log"
require "base64"
require "./command_runner"

module Autobot
  module Tools
    # Kernel-enforced sandboxing for command execution
    # Uses bubblewrap or Docker to restrict file access at OS level
    class Sandbox
      Log = ::Log.for(self)

      DOCKER_MEMORY_LIMIT   = "512m"
      DOCKER_CPU_LIMIT      = "1"
      DOCKER_DEFAULT_IMAGE  = "alpine:latest"
      DOCKER_NAME_PREFIX    = "autobot-sandbox-"
      SANDBOX_DOCKERFILE    = "Dockerfile.sandbox"
      SANDBOX_IMAGE_TAG     = "autobot-sandbox"
      DEFAULT_MAX_FILE_SIZE = 1_000_000
      READ_FILE_TIMEOUT     =        10
      WRITE_FILE_TIMEOUT    =        30
      LIST_DIR_TIMEOUT      =        10
      MKDIR_TIMEOUT         =         5
      MAX_WRITE_OUTPUT      =    10_000
      MAX_LIST_OUTPUT       =   100_000

      DISABLED_CONFIG        = "none"
      BWRAP_INSTALL_COMMAND  = "sudo apt install bubblewrap"
      DOCKER_INSTALL_COMMAND = "sudo apt install docker.io"

      enum Type
        Bubblewrap
        Docker
        External
        None

        def host? : Bool
          external? || none?
        end

        def host_exec? : Bool
          none?
        end

        def banner : String
          case self
          in Bubblewrap then "✓ Sandbox: bubblewrap (kernel-enforced isolation)"
          in Docker     then "✓ Sandbox: docker (container isolation)"
          in External   then "⚠️  #{EXTERNAL_WARNING}"
          in None       then "⚠️  #{Sandbox.host_exec_warning}"
          end
        end
      end

      record Assessment, level : Level, type : Type?, summary : String, message : String, hints : Array(String) do
        enum Level
          Ok
          Warn
          Error
        end
      end

      VALID_CONFIGS = ["auto", "bubblewrap", "docker", "external", "none"]

      EXTERNAL_WARNING      = "Sandbox: external (not verified): commands run directly because you declared autobot already runs inside your own container or VM"
      EXTERNAL_HINT         = "autobot trusts that it already runs inside your own container or VM; commands run directly"
      ISOLATE_HINT          = "set sandbox: auto, bubblewrap or docker to isolate them"
      EXTERNAL_OR_NONE_HINT = "set sandbox: external inside your own container or VM, or sandbox: none to run on this host on purpose"
      NO_BACKEND_MESSAGE    = "No sandbox backend found for sandbox: auto (install bubblewrap or docker). " \
                              "autobot never falls back to running commands on the host; " \
                              "set sandbox: external if autobot already runs inside your own container or VM, " \
                              "or sandbox: none to run commands on this host on purpose. See #{WEBSITE_URL}/sandboxing/"

      def self.host_exec_warning : String
        "host exec enabled (sandbox: none): commands and skill scripts run on this host as #{ENV["USER"]? || "unknown"}"
      end

      # One judgement of a `tools.sandbox` setting, rendered by the validator and doctor.
      def self.assess(config : String) : Assessment
        type = resolve_type?(config)
        return invalid_assessment(config) unless type
        return host_exec_assessment(type) if disabled?(config)
        return Assessment.new(Assessment::Level::Warn, type, "Sandbox: external (not verified)", EXTERNAL_WARNING, [EXTERNAL_HINT]) if type.external?
        return unavailable_assessment(type) unless available?(type)

        summary = "Sandbox available (#{type.to_s.downcase})"
        Assessment.new(Assessment::Level::Ok, type, summary, summary, [] of String)
      end

      private def self.invalid_assessment(config : String) : Assessment
        summary = "Invalid sandbox setting (#{config})"
        choices = "Use one of: #{VALID_CONFIGS.join(", ")}"
        Assessment.new(Assessment::Level::Error, nil, summary, "#{summary}. #{choices}.", [choices])
      end

      private def self.host_exec_assessment(type : Type) : Assessment
        Assessment.new(
          Assessment::Level::Warn, type,
          "Host exec: enabled by sandbox: none",
          "#{host_exec_warning}. #{ISOLATE_HINT.capitalize}.",
          ["commands and skill scripts run on this host; #{ISOLATE_HINT}"],
        )
      end

      private def self.unavailable_assessment(type : Type) : Assessment
        if type.none?
          hints = install_hints(type) << EXTERNAL_OR_NONE_HINT
          return Assessment.new(Assessment::Level::Error, type, "No sandbox backend found for sandbox: auto", NO_BACKEND_MESSAGE, hints)
        end

        summary = "Sandbox unavailable: #{unavailable_reason(type)}"
        hints = install_hints(type)
        message = "#{summary}. #{hints.join(". ")}. See #{WEBSITE_URL}/sandboxing/"
        Assessment.new(Assessment::Level::Error, type, summary, message, hints)
      end

      # Test override for sandbox detection (set to nil to use real detection)
      def self.detect_override : Type?
        @@detect_override
      end

      def self.detect_override=(@@detect_override : Type?) : Type?
        @@configured_type = nil
        @@detect_override
      end

      @@detect_override : Type? = nil

      # Custom Docker image (set from config at startup)
      class_property docker_image : String? = nil

      # Env var names to forward into Docker containers (set from config at startup).
      # Only listed variables are forwarded — empty by default for security.
      class_property sandbox_env : Array(String) = [] of String

      # Cached result of detect_type and binary checks (avoids redundant subprocess calls)
      @@cached_type : Type? = nil
      @@bwrap_available : Bool? = nil
      @@docker_available : Bool? = nil
      @@configured_type : Type? = nil

      # Active sandbox type (configured type, or auto-detected if not yet configured)
      def self.type : Type
        @@configured_type || detect
      end

      # True when sandboxing was explicitly disabled via `sandbox: "none"`
      def self.disabled?(config : String) : Bool
        config.downcase == DISABLED_CONFIG
      end

      # Configure active sandbox mode from config string ("auto", "bubblewrap", "docker", "none")
      def self.configure(config : String) : Type
        resolved = resolve_type(config)
        @@configured_type = resolved
        resolved
      end

      def self.unavailable_reason(type : Type = self.type) : String
        return "install bubblewrap or docker, or set sandbox: external or none explicitly" if type.none?

        "#{type.to_s.downcase} is configured but not installed"
      end

      def self.install_hints(type : Type = self.type) : Array(String)
        hints = [] of String
        hints << "Install bubblewrap: #{Sandbox::BWRAP_INSTALL_COMMAND}" unless type.docker?
        hints << "Install Docker: #{Sandbox::DOCKER_INSTALL_COMMAND}" unless type.bubblewrap?
        hints << "Or set sandbox: auto to use whichever tool is installed" unless type.none?
        hints
      end

      # Detect available sandbox tool (memoized)
      def self.detect : Type
        if override = @@detect_override
          return override
        end
        @@cached_type ||= detect_type
      end

      private def self.detect_type : Type
        if bwrap_available?
          Type::Bubblewrap
        elsif docker_available?
          Type::Docker
        else
          Type::None
        end
      end

      private def self.bwrap_available? : Bool
        available = @@bwrap_available
        return available unless available.nil?
        @@bwrap_available = command_exists?("bwrap")
      end

      private def self.docker_available? : Bool
        available = @@docker_available
        return available unless available.nil?
        @@docker_available = command_exists?("docker")
      end

      # Check if sandboxing is available for the active (or given) sandbox type
      def self.available?(type : Type = self.type) : Bool
        if override = @@detect_override
          return override != Type::None && override == type
        end

        case type
        in Type::Bubblewrap then bwrap_available?
        in Type::Docker     then docker_available?
        in Type::External   then true
        in Type::None       then false
        end
      end

      # Resolve sandbox type from config string, or nil if invalid
      def self.resolve_type?(config : String) : Type?
        case config.downcase
        when "bubblewrap"    then Type::Bubblewrap
        when "docker"        then Type::Docker
        when "external"      then Type::External
        when DISABLED_CONFIG then Type::None
        when "auto"          then detect
        else                      nil
        end
      end

      # Resolve sandbox type from config string. `auto` never resolves to
      # host execution: with no backend installed it raises instead.
      def self.resolve_type(config : String) : Type
        resolved = resolve_type?(config) || raise ArgumentError.new(
          "Invalid sandbox config: #{config}. Use #{VALID_CONFIGS.map { |name| "'#{name}'" }.join(", ")}"
        )
        raise SandboxNotFoundError.new if resolved.none? && !disabled?(config)
        resolved
      end

      # Execute a shell command in sandbox (for arbitrary commands with pipes/redirects).
      def self.exec(
        command : String,
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32 = CommandRunner::DEFAULT_MAX_OUTPUT,
      ) : CommandRunner::Result
        Log.debug { "Executing shell command in sandbox: #{command}" }
        run_in_sandbox(["sh", "-c", command], workspace, timeout, max_output_size)
      end

      # Execute a program with explicit args in sandbox (no shell interpretation).
      # Safer than exec for structured operations like file reads.
      def self.exec_program(
        program : String,
        args : Array(String),
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32 = CommandRunner::DEFAULT_MAX_OUTPUT,
      ) : CommandRunner::Result
        Log.debug { "Executing program in sandbox: #{program} #{args.join(" ")}" }
        run_in_sandbox([program] + args, workspace, timeout, max_output_size)
      end

      private def self.run_in_sandbox(
        cmd_args : Array(String),
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32,
      ) : CommandRunner::Result
        raise SandboxNotFoundError.new unless available?

        case type
        when Type::Bubblewrap
          run_in_bubblewrap(cmd_args, workspace, timeout, max_output_size)
        when Type::Docker
          run_in_docker(cmd_args, workspace, timeout, max_output_size)
        else
          raise SandboxNotFoundError.new
        end
      end

      # /usr/bin/python3 and friends are symlinks into /etc/alternatives on Debian-based hosts
      SYSTEM_CONFIG_PATHS = [
        "/etc/alternatives",
        "/etc/ld.so.cache",
        "/etc/ld.so.conf",
        "/etc/ld.so.conf.d",
        "/etc/resolv.conf",
        "/etc/hosts",
        "/etc/nsswitch.conf",
        "/etc/ssl",
        "/etc/ca-certificates",
        "/etc/localtime",
        "/etc/passwd",
        "/etc/group",
        "/etc/matplotlibrc", # Debian's python3-matplotlib keeps its only matplotlibrc here
      ]

      private def self.run_in_bubblewrap(
        cmd_args : Array(String),
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32,
      ) : CommandRunner::Result
        workspace_real = File.realpath(workspace.to_s)

        args = [
          "--ro-bind", "/usr", "/usr",
          "--ro-bind", "/lib", "/lib",
          "--ro-bind", "/bin", "/bin",
          "--ro-bind", "/sbin", "/sbin",
          "--bind", workspace_real, workspace_real,
          "--proc", "/proc",
          "--dev", "/dev",
          "--unshare-all",
          "--share-net",
          "--die-with-parent",
          "--chdir", workspace_real,
        ]
        args.push("--ro-bind", "/lib64", "/lib64") if Dir.exists?("/lib64")
        args.concat(system_config_binds)
        args.push("--tmpfs", "/tmp")
        args.push("--")
        args.concat(cmd_args)

        CommandRunner.run("bwrap", args, timeout, max_output_size)
      end

      def self.system_config_binds(paths : Array(String) = SYSTEM_CONFIG_PATHS) : Array(String)
        paths.select { |path| File.exists?(path) }.flat_map { |path| ["--ro-bind", path, path] }
      end

      private def self.run_in_docker(
        cmd_args : Array(String),
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32,
      ) : CommandRunner::Result
        workspace_real = File.realpath(workspace.to_s)
        image = @@docker_image || DOCKER_DEFAULT_IMAGE

        ensure_docker_image(image)

        container = "#{DOCKER_NAME_PREFIX}#{Random::Secure.hex(8)}"
        args = [
          "run",
          "--rm",
          "--name", container,
          "-v", "#{workspace_real}:#{workspace_real}:rw",
          "-w", workspace_real,
          "--network", "bridge",
          "--memory", DOCKER_MEMORY_LIMIT,
          "--cpus", DOCKER_CPU_LIMIT,
        ]
        forward_env_vars(args)
        args << image
        args.concat(cmd_args)

        result = CommandRunner.run("docker", args, timeout, max_output_size)
        remove_docker_container(container) if result.timed_out?
        result
      end

      # Killing the docker client on timeout leaves its container running.
      private def self.remove_docker_container(name : String) : Nil
        Log.debug { "Removing timed out sandbox container: #{name}" }
        Process.run("docker", ["rm", "--force", name],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close)
      end

      # Forward explicitly allowed environment variables to Docker container.
      # Only variables listed in `sandbox_env` config are forwarded.
      def self.forward_env_vars(args : Array(String)) : Nil
        @@sandbox_env.each do |key|
          if value = ENV[key]?
            args.push("--env", "#{key}=#{value}")
          end
        end
      end

      # Resolve the Docker image to use, checking for a Dockerfile.sandbox
      # in the given directory. If found and no explicit docker_image is set,
      # builds and caches the image automatically.
      def self.resolve_sandbox_image(config_dir : Path) : Nil
        return if @@docker_image # explicit override takes priority

        dockerfile = config_dir / SANDBOX_DOCKERFILE
        return unless File.exists?(dockerfile)

        if docker_image_exists?(SANDBOX_IMAGE_TAG)
          @@docker_image = SANDBOX_IMAGE_TAG
          Log.debug { "Using sandbox image: #{SANDBOX_IMAGE_TAG}" }
        else
          if build_sandbox_image(dockerfile)
            @@docker_image = SANDBOX_IMAGE_TAG
          end
        end
      end

      # Build the sandbox Docker image from a Dockerfile.
      def self.build_sandbox_image(dockerfile : Path) : Bool
        Log.info { "Building sandbox image from #{dockerfile}..." }
        status = Process.run(
          "docker", ["build", "-t", SANDBOX_IMAGE_TAG, "-f", dockerfile.to_s, dockerfile.parent.to_s],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close
        )
        if status.success?
          Log.info { "Sandbox image built: #{SANDBOX_IMAGE_TAG}" }
          true
        else
          Log.warn { "Failed to build sandbox image from #{dockerfile}" }
          false
        end
      end

      # Pulls the Docker image if not available locally.
      private def self.ensure_docker_image(image : String) : Nil
        return if docker_image_exists?(image)

        Log.info { "Pulling Docker image: #{image}" }
        status = Process.run("docker", ["pull", image],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close)
        if status.success?
          Log.info { "Docker image pulled: #{image}" }
        else
          Log.warn { "Failed to pull Docker image: #{image}" }
        end
      end

      def self.docker_image_exists?(image : String) : Bool
        Process.run("docker", ["image", "inspect", image],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?
      rescue
        false
      end

      def self.read_file(path : String, workspace : Path, max_size : Int32 = DEFAULT_MAX_FILE_SIZE) : {Bool, String}
        result = exec_program("cat", [path], workspace, READ_FILE_TIMEOUT, max_size)

        {result.success?, result.success? ? result.stdout : result.stderr}
      end

      # Read a file and return its contents as base64-encoded string.
      # Safe for binary files (images, GIFs, documents).
      def self.read_file_base64(path : String, workspace : Path, max_size : Int32 = DEFAULT_MAX_FILE_SIZE) : {Bool, String}
        b64_max = (max_size * 4 / 3).to_i + 100
        result = exec_program("base64", [path], workspace, READ_FILE_TIMEOUT, b64_max)

        if result.success?
          {true, result.stdout.gsub(/\s/, "")}
        else
          {false, result.stderr}
        end
      end

      def self.write_file(path : String, content : String, workspace : Path) : {Bool, String}
        dir = File.dirname(path)
        if dir != "." && dir != "/"
          mkdir = exec_program("mkdir", ["-p", dir], workspace, MKDIR_TIMEOUT)
          return {false, mkdir.stderr} unless mkdir.success?
        end

        # Base64 encoding prevents shell escaping issues with special characters.
        # The pipe and redirect require sh -c.
        encoded = Base64.strict_encode(content)
        command = "base64 -d > #{shell_escape(path)}"
        result = exec(
          "printf '%s' '#{encoded}' | #{command}",
          workspace, timeout: WRITE_FILE_TIMEOUT, max_output_size: MAX_WRITE_OUTPUT
        )

        message = result.success? ? "Wrote #{content.bytesize} bytes" : result.stderr
        {result.success?, message}
      end

      def self.list_dir(path : String, workspace : Path) : {Bool, String}
        result = exec_program("ls", ["-1a", path], workspace, LIST_DIR_TIMEOUT, MAX_LIST_OUTPUT)

        {result.success?, result.success? ? result.stdout : result.stderr}
      end

      def self.shell_escape(arg : String) : String
        "'#{arg.gsub("'", "'\\''")}'"
      end

      EXTRA_SEARCH_PATHS = ["/usr/local/bin", "/opt/homebrew/bin"]

      private def self.command_exists?(cmd : String) : Bool
        ensure_path!
        Process.run("which", [cmd], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      rescue
        false
      end

      # Ensure well-known binary directories are in PATH.
      # Services (systemd, launchd) often start with a minimal PATH
      # that doesn't include /usr/local/bin or /opt/homebrew/bin.
      private def self.ensure_path! : Nil
        return if @@path_ensured
        @@path_ensured = true

        current = ENV.fetch("PATH", "")
        dirs = current.split(':')
        missing = EXTRA_SEARCH_PATHS.reject { |dir| dirs.includes?(dir) }
        ENV["PATH"] = (dirs + missing).join(':') unless missing.empty?
      end

      @@path_ensured = false
    end

    # Exception raised when sandbox tools are not available
    class SandboxNotFoundError < Exception
      def initialize
        super(build_error_message)
      end

      private def build_error_message : String
        <<-ERROR
        ╔══════════════════════════════════════════════════════════╗
        ║  SECURITY ERROR: No sandbox tool found                   ║
        ╚══════════════════════════════════════════════════════════╝

        Autobot requires sandboxing to safely restrict LLM file access.

        Install one of:

        • bubblewrap (recommended for Linux):
            Ubuntu/Debian: #{Sandbox::BWRAP_INSTALL_COMMAND}
            Fedora:        sudo dnf install bubblewrap
            Arch:          sudo pacman -S bubblewrap

        • Docker (required for macOS, universal):
            macOS:         https://docs.docker.com/desktop/install/mac-install/
            Linux:         #{Sandbox::DOCKER_INSTALL_COMMAND}
            Others:        https://docs.docker.com/engine/install/

        Learn more: #{WEBSITE_URL}/sandboxing/
        ERROR
      end
    end
  end
end
