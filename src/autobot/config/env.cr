module Autobot::Config
  # .env file detection and protection utilities
  module Env
    # Pattern for detecting .env files
    # Matches: .env, .env.local, .env.production, secrets.env, etc.
    FILE_PATTERN = /\.env(?:\.|$)/

    # Check if a path points to an .env file (always blocked for security)
    #
    # This checks for various .env file naming patterns:
    # - .env
    # - .env.local, .env.production, .env.development
    # - config.env, secrets.env, etc.
    def self.file?(path : Path | String) : Bool
      basename = Path[path].basename.to_s

      # Direct matches
      return true if basename == ".env"
      return true if basename.starts_with?(".env.")

      # Pattern match for files ending in .env
      !basename.match(FILE_PATTERN).nil?
    end

    # Check if a command string references .env files
    def self.command_references_file?(command : String) : Bool
      !command.match(FILE_PATTERN).nil?
    end
  end
end
