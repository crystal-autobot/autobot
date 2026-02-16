require "yaml"
require "./schema"

module Autobot::Config
  # Configuration loader with precedence:
  # 1. --config CLI flag
  # 2. ./config.yml (current directory)
  # 3. Default values from schema
  class Loader
    # Default config path (relative to current directory)
    PROJECT_CONFIG_PATH = Path["config.yml"]

    # Config directory — set when config is loaded, defaults to current dir
    @@config_dir : Path = Path["."]

    def self.config_dir : Path
      @@config_dir
    end

    # Load configuration with proper precedence
    def self.load(config_path : String? = nil, *, validate : Bool = true) : Config
      path = resolve_config_path(config_path)

      if path && File.exists?(path)
        @@config_dir = path.parent
        # Load .env file first (if exists)
        load_env_file(path.parent)
        load_from_file(path, validate: validate)
      else
        Log.info { "No config file found, using defaults" }
        # Return minimal default config
        Config.from_yaml("{}")
      end
    end

    # Save configuration to file
    def self.save(config : Config, path : String? = nil) : Nil
      save_path = Path[path || (@@config_dir / "config.yml").to_s]

      # Create parent directory with restrictive permissions (user-only)
      unless Dir.exists?(save_path.parent)
        Dir.mkdir_p(save_path.parent)
        File.chmod(save_path.parent, 0o700)
      end

      # Write config with restrictive permissions (user read/write only)
      File.write(save_path, config.to_yaml)
      File.chmod(save_path, 0o600)
      Log.info { "Config saved to #{save_path}" }
    end

    # Get default data directory (relative to config directory)
    def self.data_dir : Path
      @@config_dir
    end

    # Get sessions directory
    def self.sessions_dir : Path
      data_dir / "sessions"
    end

    # Get skills directory
    def self.skills_dir : Path
      data_dir / "skills"
    end

    # Get logs directory
    def self.logs_dir : Path
      data_dir / "logs"
    end

    # Get cron store path
    def self.cron_store_path : Path
      data_dir / "cron.json"
    end

    # Resolve config path for display purposes (doesn't raise if missing).
    def self.resolve_display_path(config_path : String?) : String
      if config_path
        return config_path
      end
      PROJECT_CONFIG_PATH.to_s
    end

    # Initialize autobot directories
    def self.init_dirs : Nil
      [data_dir, sessions_dir, skills_dir, logs_dir].each do |dir|
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
      end
    end

    # Strip surrounding quotes from a value string
    # Handles both double and single quotes
    private def self.strip_quotes(value : String) : String
      QUOTE_CHARS.each do |quote|
        if value.starts_with?(quote) && value.ends_with?(quote) && value.size >= 2
          return value[1..-2]
        end
      end
      value
    end

    # Quote characters used in .env files
    QUOTE_CHARS = ['"', '\'']

    # Load environment variables from .env file in config directory
    private def self.load_env_file(config_dir : Path) : Nil
      env_path = config_dir / ".env"
      return unless File.exists?(env_path)

      Log.debug { "Loading .env from #{env_path}" }

      File.each_line(env_path) do |line|
        line = line.strip
        # Skip empty lines and comments
        next if line.empty? || line.starts_with?("#")

        # Parse KEY=VALUE format
        parts = line.split("=", 2)
        next unless parts.size == 2

        key = parts[0].strip
        value = strip_quotes(parts[1].strip)

        ENV[key] = value unless key.empty?
      end

      Log.info { "Loaded environment variables from .env" }
    rescue ex
      Log.warn { "Failed to load .env file: #{ex.message}" }
    end

    # Resolve config file path with precedence
    private def self.resolve_config_path(explicit_path : String?) : Path?
      # 1. Explicit path from CLI
      if explicit_path
        path = Path[explicit_path]
        return path.expand(home: true) if File.exists?(path)
        raise "Config file not found: #{explicit_path}"
      end

      # 2. Current directory ./config.yml
      if File.exists?(PROJECT_CONFIG_PATH)
        return PROJECT_CONFIG_PATH
      end

      nil
    end

    # Load configuration from YAML file
    private def self.load_from_file(path : Path, *, validate : Bool = true) : Config
      content = File.read(path)
      # Expand environment variables in format ${VAR} or $VAR
      expanded = expand_env_vars(content)
      config = Config.from_yaml(expanded)
      config.validate! if validate
      config
    rescue ex : YAML::ParseException
      Log.error { "Failed to parse config file #{path}: #{ex.message}" }
      raise "Invalid YAML in config file: #{ex.message}"
    rescue ex : Exception
      Log.error { "Failed to load config from #{path}: #{ex.message}" }
      raise "Failed to load configuration: #{ex.message}"
    end

    # Expand environment variables in content
    # Supports ${VAR_NAME} and $VAR_NAME formats
    private def self.expand_env_vars(content : String) : String
      # First expand ${VAR_NAME} format
      result = content.gsub(/\$\{([A-Z_][A-Z0-9_]*)\}/) do |match, matcher|
        var_name = matcher[1]
        ENV[var_name]? || match
      end

      # Then expand $VAR_NAME format (but not ${ which we already handled)
      result.gsub(/\$([A-Z_][A-Z0-9_]*)(?!\{)/) do |match, matcher|
        var_name = matcher[1]
        ENV[var_name]? || match
      end
    end
  end

  # Logging module
  Log = ::Log.for("config")
end
