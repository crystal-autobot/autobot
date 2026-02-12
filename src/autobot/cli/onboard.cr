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
        config_file = config_path || Config::Loader::GLOBAL_CONFIG_PATH.to_s

        if File.exists?(config_file)
          print "Config already exists at #{config_file}. Overwrite? [y/N] "
          answer = gets
          unless answer && answer.strip.downcase == "y"
            puts "Aborted."
            return
          end
        end

        # Create default config with YAML
        defaults = Config::AgentDefaults.new
        config_yaml = <<-YAML
        agents:
          defaults:
            workspace: "#{defaults.workspace}"
            model: "#{defaults.model}"
        providers:
          anthropic:
            api_key: ""
        YAML
        config = Config::Config.from_yaml(config_yaml)
        Config::Loader.save(config, config_file)
        puts "✓ Created config at #{config_file}"

        # Initialize directories
        Config::Loader.init_dirs
        puts "✓ Created data directories"

        # Create workspace
        workspace = config.workspace_path
        Dir.mkdir_p(workspace) unless Dir.exists?(workspace)
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

        puts "\n#{LOGO.strip}"
        puts "\nautobot is ready!\n"
        puts "Next steps:"
        puts "  1. Add your API key to #{config_file}"
        puts "  2. Chat: autobot agent -m \"Hello!\""
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
