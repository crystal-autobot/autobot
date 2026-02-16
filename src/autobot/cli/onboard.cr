module Autobot
  module CLI
    module Onboard
      WORKSPACE_TEMPLATES = {
        "AGENTS.md" => <<-MD,
        # Agent Instructions

        You are a helpful AI assistant. Be concise, accurate, and friendly.

        ## Guidelines

        - Always explain what you're doing before taking actions
        - Ask for clarification when the request is ambiguous
        - Use tools to help accomplish tasks
        - Remember important information in memory/MEMORY.md
        MD

        "SOUL.md" => <<-MD,
        # Soul

        I am Autobot, a fast and extensible AI agent.

        ## Personality

        - Helpful and friendly
        - Concise and to the point
        - Curious and eager to learn

        ## Values

        - Accuracy over speed
        - User privacy and safety
        - Transparency in actions
        MD

        "USER.md" => <<-MD,
        # User

        Information about the user goes here.

        ## Preferences

        - Communication style: (casual/formal)
        - Timezone: (your timezone)
        - Language: (your preferred language)
        MD
      }

      def self.run(config_path : String?) : Nil
        # Determine config directory (use explicit path or current directory)
        base_dir = if config_path
                     Path[config_path].parent
                   else
                     Config::Loader::PROJECT_CONFIG_PATH.parent
                   end

        config_file = base_dir / "config.yml"
        env_file = base_dir / ".env"

        if File.exists?(config_file)
          print "Config already exists at #{config_file}. Overwrite? [y/N] "
          answer = gets
          unless answer && answer.strip.downcase == "y"
            puts "Aborted."
            return
          end
        end

        # Create directory if needed
        unless Dir.exists?(base_dir)
          Dir.mkdir_p(base_dir)
          File.chmod(base_dir, 0o700)
        end

        # Create .env file with template
        env_template = <<-ENV
        # API Keys (required - add at least one)
        ANTHROPIC_API_KEY=
        # OPENAI_API_KEY=
        # OPENROUTER_API_KEY=

        # Channel tokens (optional)
        # TELEGRAM_BOT_TOKEN=
        # SLACK_BOT_TOKEN=
        # SLACK_APP_TOKEN=

        # Web search (optional)
        # BRAVE_API_KEY=
        ENV

        File.write(env_file, env_template)
        File.chmod(env_file, 0o600)
        puts "✓ Created .env at #{env_file}"

        # Create config.yml with environment variable references
        workspace_path = "./workspace"
        defaults = Config::AgentDefaults.new
        config_yaml = <<-YAML
        agents:
          defaults:
            workspace: "#{workspace_path}"
            model: "#{defaults.model}"
            max_tokens: #{defaults.max_tokens}
            temperature: #{defaults.temperature}

        providers:
          anthropic:
            api_key: "${ANTHROPIC_API_KEY}"
          # openai:
          #   api_key: "${OPENAI_API_KEY}"

        channels:
          telegram:
            enabled: false
            token: "${TELEGRAM_BOT_TOKEN}"
            allow_from: []  # Add Telegram user IDs to enable

        tools:
          sandbox: "auto"  # auto|bubblewrap|docker|none
          exec:
            timeout: 60

        gateway:
          host: "127.0.0.1"
          port: 18790
        YAML

        File.write(config_file, config_yaml)
        File.chmod(config_file, 0o600)
        puts "✓ Created config at #{config_file}"

        # Initialize data directories
        {"sessions", "logs"}.each do |dir|
          dir_path = base_dir / dir
          Dir.mkdir_p(dir_path) unless Dir.exists?(dir_path)
        end
        puts "✓ Created data directories"

        # Parse config to get workspace path
        config = Config::Config.from_yaml(config_yaml)
        workspace = config.workspace_path
        Dir.mkdir_p(workspace) unless Dir.exists?(workspace)
        File.chmod(workspace, 0o700)
        puts "✓ Created workspace at #{workspace}"

        # Create workspace templates
        create_templates(workspace)

        # Create memory directory
        memory_dir = workspace / "memory"
        Dir.mkdir_p(memory_dir) unless Dir.exists?(memory_dir)

        memory_file = memory_dir / "MEMORY.md"
        unless File.exists?(memory_file)
          File.write(memory_file, <<-MD)
          # Long-term Memory

          This file stores important information that should persist across sessions.

          ## User Information

          (Important facts about the user)

          ## Preferences

          (User preferences learned over time)
          MD
          puts "  Created memory/MEMORY.md"
        end

        history_file = memory_dir / "HISTORY.md"
        unless File.exists?(history_file)
          File.write(history_file, "")
          puts "  Created memory/HISTORY.md"
        end

        # Create skills directory
        skills_dir = workspace / "skills"
        Dir.mkdir_p(skills_dir) unless Dir.exists?(skills_dir)

        # Create .gitignore
        gitignore_file = base_dir / ".gitignore"
        unless File.exists?(gitignore_file)
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
          File.write(gitignore_file, gitignore_content)
          puts "✓ Created .gitignore"
        end

        puts "\n#{LOGO.strip}"
        puts "\nautobot is ready!\n"
        puts "Next steps:"
        puts "  1. Edit #{env_file} and add your API keys"
        puts "  2. Run: autobot doctor (check configuration)"
        puts "  3. Start: autobot gateway"
        puts "  4. Or chat: autobot agent -m \"Hello!\""
      end

      private def self.create_templates(workspace : Path) : Nil
        WORKSPACE_TEMPLATES.each do |filename, content|
          file_path = workspace / filename
          unless File.exists?(file_path)
            File.write(file_path, content)
            puts "  Created #{filename}"
          end
        end
      end
    end
  end
end
