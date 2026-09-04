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
      !restricted? || !matching_pattern(name).nil?
    end

    def matching_pattern(name : String) : String?
      @patterns.find { |pattern| Allowlist.matches?(pattern, name) }
    end

    def self.matches?(pattern : String, name : String) : Bool
      pattern.ends_with?("*") ? name.starts_with?(pattern.rchop("*")) : name == pattern
    end
  end
end
