module Autobot
  module Agent
    # Skill info returned by list_skills.
    struct SkillInfo
      property name : String
      property path : String
      property source : String # "workspace" or "builtin"

      def initialize(@name, @path, @source)
      end
    end

    # Parsed frontmatter metadata from a SKILL.md file.
    struct SkillMetadata
      property description : String?
      property? always : Bool
      property tool : String?
      property requires_bins : Array(String)
      property requires_env : Array(String)
      property raw : Hash(String, String)

      def initialize(
        @description = nil,
        @always = false,
        @tool = nil,
        @requires_bins = [] of String,
        @requires_env = [] of String,
        @raw = {} of String => String,
      )
      end
    end

    # Loader for agent skills.
    #
    # Skills are markdown files (SKILL.md) that teach the agent how to use
    # specific tools or perform certain tasks. They live in directories under
    # `skills/` in the workspace or builtin skills directory.
    class SkillsLoader
      BUILTIN_SKILLS_DIR = Path[__DIR__].parent.parent / "skills"

      @workspace : Path
      @workspace_skills : Path
      @builtin_skills : Path

      def initialize(@workspace : Path, builtin_skills_dir : Path? = nil)
        @workspace_skills = @workspace / "skills"
        @builtin_skills = builtin_skills_dir || BUILTIN_SKILLS_DIR
      end

      # List all available skills.
      def list_skills(filter_unavailable : Bool = true) : Array(SkillInfo)
        skills = [] of SkillInfo

        # Workspace skills (highest priority)
        if Dir.exists?(@workspace_skills)
          Dir.each_child(@workspace_skills) do |child|
            skill_dir = @workspace_skills / child
            next unless File.directory?(skill_dir)
            skill_file = skill_dir / "SKILL.md"
            if File.exists?(skill_file)
              skills << SkillInfo.new(name: child, path: skill_file.to_s, source: "workspace")
            end
          end
        end

        # Built-in skills
        if Dir.exists?(@builtin_skills)
          Dir.each_child(@builtin_skills) do |child|
            skill_dir = @builtin_skills / child
            next unless File.directory?(skill_dir)
            skill_file = skill_dir / "SKILL.md"
            if File.exists?(skill_file) && !skills.any? { |skill_info| skill_info.name == child }
              skills << SkillInfo.new(name: child, path: skill_file.to_s, source: "builtin")
            end
          end
        end

        if filter_unavailable
          skills.select { |skill_info| check_requirements(get_skill_metadata(skill_info.name)) }
        else
          skills
        end
      end

      # Load a skill's content by name.
      def load_skill(name : String) : String?
        workspace_skill = @workspace_skills / name / "SKILL.md"
        return File.read(workspace_skill) if File.exists?(workspace_skill)

        builtin_skill = @builtin_skills / name / "SKILL.md"
        return File.read(builtin_skill) if File.exists?(builtin_skill)

        nil
      end

      # Load specific skills for inclusion in agent context.
      def load_skills_for_context(skill_names : Array(String)) : String
        parts = [] of String
        skill_names.each do |name|
          content = load_skill(name)
          if content
            content = strip_frontmatter(content)
            parts << "### Skill: #{name}\n\n#{content}"
          end
        end
        parts.join("\n\n---\n\n")
      end

      # Build an XML summary of all skills for progressive loading.
      def build_skills_summary : String
        all_skills = list_skills(filter_unavailable: false)
        return "" if all_skills.empty?

        lines = ["<skills>"]
        all_skills.each do |skill_info|
          meta = get_skill_metadata(skill_info.name)
          available = check_requirements(meta)
          desc = meta.description || skill_info.name

          lines << "  <skill available=\"#{available}\">"
          lines << "    <name>#{escape_xml(skill_info.name)}</name>"
          lines << "    <description>#{escape_xml(desc)}</description>"
          lines << "    <location>#{skill_info.path}</location>"

          unless available
            missing = get_missing_requirements(meta)
            lines << "    <requires>#{escape_xml(missing)}</requires>" unless missing.empty?
          end

          lines << "  </skill>"
        end
        lines << "</skills>"
        lines.join("\n")
      end

      # Get skills marked as always=true that meet requirements.
      def always_skills : Array(String)
        list_skills(filter_unavailable: true)
          .select { |skill_info| get_skill_metadata(skill_info.name).always? }
          .map(&.name)
      end

      # Get skills linked to specific tools via the `tool` frontmatter field.
      def tool_skills(tool_names : Array(String)) : Array(String)
        return [] of String if tool_names.empty?

        tool_set = tool_names.to_set
        list_skills(filter_unavailable: true)
          .select { |skill_info|
            tool = get_skill_metadata(skill_info.name).tool
            tool && tool_set.includes?(tool)
          }
          .map(&.name)
      end

      # Parse frontmatter metadata from a SKILL.md file.
      def get_skill_metadata(name : String) : SkillMetadata
        content = load_skill(name)
        return SkillMetadata.new unless content

        parse_frontmatter(content)
      end

      private def parse_frontmatter(content : String) : SkillMetadata
        return SkillMetadata.new unless content.starts_with?("---")

        if match = content.match(/\A---\n(.*?)\n---/m)
          raw = {} of String => String
          match[1].split("\n").each do |line|
            if colon_idx = line.index(':')
              key = line[0...colon_idx].strip
              value = line[(colon_idx + 1)..].strip.strip('"').strip('\'')
              raw[key] = value
            end
          end

          bins, env = parse_requires(raw["metadata"]?)

          SkillMetadata.new(
            description: raw["description"]?,
            always: raw["always"]? == "true",
            tool: raw["tool"]?,
            requires_bins: bins,
            requires_env: env,
            raw: raw
          )
        else
          SkillMetadata.new
        end
      end

      private def parse_requires(metadata_json : String?) : {Array(String), Array(String)}
        empty = {[] of String, [] of String}
        return empty unless metadata_json

        parsed = JSON.parse(metadata_json)
        config = parsed["autobot"]? || parsed["nanobot"]?
        return empty unless config

        requires = config["requires"]?
        return empty unless requires

        bins = requires["bins"]?.try(&.as_a.map(&.as_s)) || [] of String
        env = requires["env"]?.try(&.as_a.map(&.as_s)) || [] of String
        {bins, env}
      rescue
        empty || {[] of String, [] of String}
      end

      private def strip_frontmatter(content : String) : String
        if content.starts_with?("---")
          if match = content.match(/\A---\n.*?\n---\n/m)
            return content[match[0].size..].strip
          end
        end
        content
      end

      private def check_requirements(meta : SkillMetadata) : Bool
        meta.requires_bins.each do |bin|
          return false unless Process.find_executable(bin)
        end
        meta.requires_env.each do |env_var|
          return false unless ENV[env_var]?
        end
        true
      end

      private def get_missing_requirements(meta : SkillMetadata) : String
        missing = [] of String
        meta.requires_bins.each do |bin|
          missing << "CLI: #{bin}" unless Process.find_executable(bin)
        end
        meta.requires_env.each do |env_var|
          missing << "ENV: #{env_var}" unless ENV[env_var]?
        end
        missing.join(", ")
      end

      private def escape_xml(s : String) : String
        s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
    end
  end
end
