module Autobot
  module CLI
    module New
      def self.run(name : String, interactive : Bool = true) : Nil
        validate_bot_name(name)
        check_directory_exists(name)

        if interactive
          run_interactive_setup(name)
        else
          run_non_interactive_setup(name)
        end
      end

      # Validates bot name
      private def self.validate_bot_name(name : String)
        if name.empty?
          STDERR.puts "Error: Bot name cannot be empty"
          STDERR.puts "Usage: autobot new <name>"
          exit 1
        end
      end

      # Checks if directory already exists
      private def self.check_directory_exists(name : String)
        if Dir.exists?(name)
          STDERR.puts "Error: Directory '#{name}' already exists"
          exit 1
        end
      end

      # Runs interactive setup with prompts
      private def self.run_interactive_setup(name : String)
        config = InteractiveSetup.run

        create_bot_directory(name) do
          write_configuration_files(config)
          create_workspace_structure
          create_gitignore
        end

        print_success_message(name, interactive: true)
      end

      # Runs non-interactive setup (original behavior)
      private def self.run_non_interactive_setup(name : String)
        puts "Creating new autobot: #{name}"

        create_bot_directory(name) do
          Onboard.run("./config.yml")
        end

        print_success_message(name, interactive: false)
      end

      # Creates bot directory and executes block within it
      private def self.create_bot_directory(name : String, &)
        begin
          Dir.mkdir(name)
          File.chmod(name, 0o700)
        rescue ex
          STDERR.puts "Error: Failed to create directory: #{ex.message}"
          exit 1
        end

        begin
          Dir.cd(name) do
            yield
          end
        rescue ex
          STDERR.puts "Error: Failed to initialize bot: #{ex.message}"
          Dir.delete(name) rescue nil
          exit 1
        end
      end

      # Writes configuration files from interactive setup
      private def self.write_configuration_files(config : InteractiveSetup::Configuration)
        env_content = ConfigGenerator.generate_env(config)
        config_content = ConfigGenerator.generate_config(config)

        File.write(".env", env_content)
        File.chmod(".env", 0o600)

        File.write("config.yml", config_content)
        File.chmod("config.yml", 0o600)
      end

      # Creates workspace directory structure
      private def self.create_workspace_structure
        workspace = Path.new("./workspace")

        Dir.mkdir_p(workspace)
        File.chmod(workspace, 0o700)

        # Create workspace templates
        Onboard::WORKSPACE_TEMPLATES.each do |filename, content|
          File.write(workspace / filename, content)
        end

        # Create memory directory
        memory_dir = workspace / "memory"
        Dir.mkdir_p(memory_dir)

        File.write(memory_dir / "MEMORY.md", <<-MD)
        # Long-term Memory

        This file stores important information that should persist across sessions.

        ## User Information

        (Important facts about the user)

        ## Preferences

        (User preferences learned over time)
        MD

        File.write(memory_dir / "HISTORY.md", "")

        # Create skills directory
        Dir.mkdir_p(workspace / "skills")

        # Create sessions and logs directories
        Dir.mkdir_p("./sessions")
        Dir.mkdir_p("./logs")
      end

      # Creates .gitignore file
      private def self.create_gitignore
        gitignore_content = <<-GITIGNORE
        # Secrets
        .env
        .env.*

        # Session data
        sessions/

        # Logs
        logs/

        # Memory (optional - comment out if you want to commit)
        workspace/memory/
        GITIGNORE

        File.write(".gitignore", gitignore_content)
      end

      # Prints success message with next steps
      private def self.print_success_message(name : String, interactive : Bool)
        puts ""
        puts "━" * 50
        puts "✅ Bot '#{name}' created successfully!"
        puts ""
        puts "Next steps:"
        puts "  cd #{name}"

        unless interactive
          puts "  # Edit .env and add your API keys"
        end

        puts "  autobot doctor    # Verify configuration"
        puts "  autobot gateway   # Start the bot"
        puts ""
      end
    end
  end
end
