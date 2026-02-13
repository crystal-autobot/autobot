module Autobot
  module CLI
    module New
      def self.run(name : String) : Nil
        # Validate name
        if name.empty?
          STDERR.puts "Error: Bot name cannot be empty"
          STDERR.puts "Usage: autobot new <name>"
          exit 1
        end

        # Check if directory already exists
        if Dir.exists?(name)
          STDERR.puts "Error: Directory '#{name}' already exists"
          exit 1
        end

        puts "Creating new autobot: #{name}"

        # Create directory
        begin
          Dir.mkdir(name)
          File.chmod(name, 0o700)
        rescue ex
          STDERR.puts "Error: Failed to create directory: #{ex.message}"
          exit 1
        end

        # Change to new directory and run onboard
        begin
          Dir.cd(name) do
            # Run onboard in the current directory (will create ./config.yml)
            Onboard.run(nil)
          end
        rescue ex
          STDERR.puts "Error: Failed to initialize bot: #{ex.message}"
          # Try to clean up
          Dir.delete(name) rescue nil
          exit 1
        end

        puts "\n✅ Bot '#{name}' created successfully!"
        puts "\nNext steps:"
        puts "  cd #{name}"
        puts "  # Edit .env and add your API keys"
        puts "  autobot doctor"
        puts "  autobot gateway"
      end
    end
  end
end
