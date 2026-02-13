require "yaml"
require "./schema"

module Autobot::Config
  # Configuration loader with precedence:
  # 1. --config CLI flag
  # 2. ./config.yml (current directory)
  # 3. ~/.config/autobot/config.yml
  # 4. Default values from schema
  class Loader
    # Default config paths
    GLOBAL_CONFIG_PATH  = Path.home / ".config" / "autobot" / "config.yml"
    PROJECT_CONFIG_PATH = Path["config.yml"]

    # Load configuration with proper precedence
    def self.load(config_path : String? = nil) : Config
      path = resolve_config_path(config_path)

      if path && File.exists?(path)
        load_from_file(path)
      else
        Log.info { "No config file found, using defaults" }
        # Return minimal default config
        Config.from_yaml("{}")
      end
    end

    # Save configuration to file
    def self.save(config : Config, path : String? = nil) : Nil
      save_path = Path[path || GLOBAL_CONFIG_PATH.to_s]

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

    # Get default data directory
    def self.data_dir : Path
      Path.home / ".config" / "autobot"
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
      if File.exists?(PROJECT_CONFIG_PATH)
        return PROJECT_CONFIG_PATH.to_s
      end
      GLOBAL_CONFIG_PATH.to_s
    end

    # Initialize autobot directories
    def self.init_dirs : Nil
      [data_dir, sessions_dir, skills_dir, logs_dir].each do |dir|
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
      end
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

      # 3. Global ~/.config/autobot/config.yml
      if File.exists?(GLOBAL_CONFIG_PATH)
        return GLOBAL_CONFIG_PATH
      end

      nil
    end

    # Load configuration from YAML file
    private def self.load_from_file(path : Path) : Config
      content = File.read(path)
      config = Config.from_yaml(content)
      config.validate!
      config
    rescue ex : YAML::ParseException
      Log.error { "Failed to parse config file #{path}: #{ex.message}" }
      raise "Invalid YAML in config file: #{ex.message}"
    rescue ex : Exception
      Log.error { "Failed to load config from #{path}: #{ex.message}" }
      raise "Failed to load configuration: #{ex.message}"
    end
  end

  # Logging module
  Log = ::Log.for("config")
end
