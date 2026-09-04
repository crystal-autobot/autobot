module Autobot::Tools
  # Empty patterns allow everything; a pattern ending in `*` matches by prefix.
  struct Allowlist
    getter patterns : Array(String)

    def self.all : Allowlist
      new([] of String)
    end

    def initialize(@patterns : Array(String))
    end

    def restricted? : Bool
      !@patterns.empty?
    end

    def allows?(name : String) : Bool
      return true unless restricted?

      @patterns.any? do |pattern|
        pattern.ends_with?("*") ? name.starts_with?(pattern.rchop("*")) : name == pattern
      end
    end
  end
end
