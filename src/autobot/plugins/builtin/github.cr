require "../plugin"
require "../../tools/result"

module Autobot
  module Plugins
    module Builtin
      # GitHub plugin that provides tools for interacting with GitHub via gh CLI.
      #
      # Requires the `gh` CLI to be installed and authenticated.
      class GithubPlugin < Plugin
        def name : String
          "github"
        end

        def description : String
          "Interact with GitHub using the gh CLI (issues, PRs, runs)"
        end

        def version : String
          "0.1.0"
        end

        def setup(context : PluginContext) : Nil
          unless Process.find_executable("gh")
            Log.warn { "GitHub plugin: 'gh' CLI not found, skipping tool registration" }
            return
          end
          context.tool_registry.register(GithubTool.new)
        end
      end

      # Tool that executes gh CLI commands.
      class GithubTool < Tools::Tool
        ALLOWED_SUBCOMMANDS = {"issue", "pr", "run", "release", "repo", "api", "search"}
        MAX_OUTPUT_CHARS    = 10_000

        def name : String
          "github"
        end

        def description : String
          "Execute GitHub CLI (gh) commands. Supports: issue, pr, run, release, repo, api, search. " \
          "Always specify --repo owner/repo when not in a git directory."
        end

        def parameters : Tools::ToolSchema
          Tools::ToolSchema.new(
            properties: {
              "command" => Tools::PropertySchema.new(
                type: "string",
                description: "The gh subcommand and arguments (e.g. 'issue list --repo owner/repo --limit 10')"
              ),
            },
            required: ["command"]
          )
        end

        def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
          args = params["command"].as_s.strip.split(/\s+/)
          subcommand = args.first?

          unless subcommand && ALLOWED_SUBCOMMANDS.includes?(subcommand)
            return Tools::ToolResult.error("Only these gh subcommands are allowed: #{ALLOWED_SUBCOMMANDS.join(", ")}")
          end

          output = IO::Memory.new
          error = IO::Memory.new

          status = Process.run(
            "gh", args,
            output: output,
            error: error,
            env: {"GH_FORCE_TTY" => "0"}
          )

          result = output.to_s.strip
          err = error.to_s.strip

          unless status.success?
            return Tools::ToolResult.error("Error running gh #{subcommand}: #{err.empty? ? "unknown error" : err}")
          end

          content = if result.size > MAX_OUTPUT_CHARS
                      result[0, MAX_OUTPUT_CHARS] + "\n... (output truncated)"
                    elsif result.empty?
                      "Command completed successfully (no output)."
                    else
                      result
                    end

          Tools::ToolResult.success(content)
        end
      end
    end
  end
end
