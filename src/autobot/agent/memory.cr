module Autobot
  module Agent
    # Two-layer memory: MEMORY.md (long-term facts) + HISTORY.md (grep-searchable log).
    class MemoryStore
      @memory_dir : Path
      @memory_file : Path
      @history_file : Path

      def initialize(workspace : Path)
        @memory_dir = workspace / "memory"
        @memory_file = @memory_dir / "MEMORY.md"
        @history_file = @memory_dir / "HISTORY.md"
        Dir.mkdir_p(@memory_dir) unless Dir.exists?(@memory_dir)
      end

      # Read long-term memory (MEMORY.md).
      def read_long_term : String
        if File.exists?(@memory_file)
          File.read(@memory_file)
        else
          ""
        end
      end

      # Write long-term memory (MEMORY.md), replacing content.
      def write_long_term(content : String) : Nil
        File.write(@memory_file, content)
      end

      # Append an entry to searchable history (HISTORY.md).
      def append_history(entry : String) : Nil
        File.open(@history_file, "a") do |history_io|
          history_io.puts(entry.rstrip)
          history_io.puts
        end
      end

      # Get memory context for inclusion in LLM system prompt.
      def memory_context : String
        long_term = read_long_term
        if long_term.empty?
          ""
        else
          "## Long-term Memory\n#{long_term}"
        end
      end
    end
  end
end
