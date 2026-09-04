module Autobot::Tools
  struct DomainAllowlist
    getter entries : Array(String)

    def initialize(entries : Array(String))
      @entries = entries.map(&.strip.downcase).reject(&.empty?)
    end

    def allows?(host : String) : Bool
      return true if @entries.empty?

      name = host.downcase
      @entries.any? do |entry|
        if entry.starts_with?("*.")
          apex = entry.lchop("*.")
          name == apex || name.ends_with?(".#{apex}")
        else
          name == entry
        end
      end
    end
  end
end
