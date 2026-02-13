require "./validator_common"
require "./security_validator"
require "./config_validator"

module Autobot::Config
  # Main validator facade that combines security and configuration validation
  module Validator
    include ValidatorCommon

    # Validate configuration and return all issues
    def self.validate(config : Config, config_path : Path) : Array(Issue)
      issues = [] of Issue

      # Security checks (critical)
      issues.concat(SecurityValidator.validate(config, config_path))

      # Configuration checks
      issues.concat(ConfigValidator.validate(config))

      issues
    end

    # Format issues for display
    def self.format_issues(issues : Array(Issue)) : String
      return "✓ All checks passed!" if issues.empty?

      errors = issues.select { |i| i.severity == Severity::Error }
      warnings = issues.select { |i| i.severity == Severity::Warning }
      infos = issues.select { |i| i.severity == Severity::Info }

      String.build do |str|
        format_issues_section(str, "❌ ERRORS", errors)
        format_issues_section(str, "⚠️  WARNINGS", warnings)
        format_issues_section(str, "ℹ️  INFO", infos)
        str << "\nSummary: #{errors.size} errors, #{warnings.size} warnings, #{infos.size} info"
      end
    end

    # Format a section of issues
    private def self.format_issues_section(str : String::Builder, header : String, issues : Array(Issue))
      return if issues.empty?
      str << "\n#{header} (#{issues.size}):\n"
      issues.each { |issue| str << "  • #{issue.message}\n" }
    end

    # Check if issues contain any errors
    def self.has_errors?(issues : Array(Issue)) : Bool
      issues.any? { |i| i.severity == Severity::Error }
    end

    # Check if issues contain any warnings
    def self.has_warnings?(issues : Array(Issue)) : Bool
      issues.any? { |i| i.severity == Severity::Warning }
    end
  end
end
