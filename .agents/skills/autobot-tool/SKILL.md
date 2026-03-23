name: autobot-tool
description: Create new tools for Autobot agent with proper schema and safety
tags:
  - tool
  - mcp
  - integration
metadata:
  scope: feature-development
---

## Creating a New Tool

### Files to Create/Modify

1. **Create tool implementation**:
   - `src/autobot/tools/<name>_tool.cr`
   - Inherit from `Tool` base class
   - Implement `Tool` interface

2. **Register tool**:
   - Tools are registered in `src/autobot/tools/registry.cr` or `src/autobot/cli/gateway.cr`.
   - Add new tool instance to the registry.

3. **Add configuration** (if configurable):
   - Update `src/autobot/config/schema.cr`
   - Add tool-specific settings

4. **Create tests**:
   - `spec/autobot/tools/<name>_tool_spec.cr`
   - Test all tool functionality
   - Test error handling
   - Test safety guards

### Tool Implementation Template

```crystal
# src/autobot/tools/<name>_tool.cr
require "./tool"

module Autobot
  module Tools
    class <Name>Tool < Tool
      # Tool metadata
      def name : String
        "<tool_name>"
      end

      def description : String
        "Description of what this tool does (1-2 sentences)"
      end

      # Define JSON schema for parameters
      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "param1" => PropertySchema.new(
              type: "string",
              description: "Description of param1"
            ),
            "param2" => PropertySchema.new(
              type: "integer",
              description: "Description of param2",
              minimum: 1_i64,
              maximum: 100_i64
            ),
          },
          required: ["param1"]
        )
      end

      # Execute the tool
      def execute(params : Hash(String, JSON::Any)) : ToolResult
        # Extract parameters
        param1 = params["param1"].as_s
        param2 = params["param2"]?.try(&.as_i) || 0

        # Execute tool logic
        begin
          result = perform_action(param1, param2)
          ToolResult.success(result)
        rescue ex
          ToolResult.error("Tool execution failed: #{ex.message}")
        end
      end

      private def perform_action(param1, param2)
        # Implement tool logic
        "result"
      end
    end
  end
end
```

### Safety and Security

**Always implement input validation:**
- Validate URLs (scheme, host, private IP ranges)
- Sanitize file paths (prevent directory traversal)
- Check command safety (for exec-like tools)
- Validate numeric ranges

### Related Files and Examples

**Base Classes:**
- `src/autobot/tools/base.cr` - Tool abstract class and ToolSchema
- `src/autobot/tools/result.cr` - ToolResult definition

**Working Examples:**
- `src/autobot/tools/exec.cr` - Command execution
- `src/autobot/tools/bash_tool.cr` - Shell execution
- `src/autobot/tools/web.cr` - HTTP fetching
- `src/autobot/tools/filesystem.cr` - File operations
- `src/autobot/tools/cron_tool.cr` - Scheduling

**Registration:**
- `src/autobot/tools/registry.cr` - Tool registry
- `src/autobot/cli/gateway.cr` - Tool instantiation

**Tests:**
- `spec/autobot/tools/exec_spec.cr` - Exec tool tests
- `spec/autobot/tools/web_spec.cr` - Web tool tests

## When to Use

Use this skill when:
- Creating a new tool for the agent
- Adding MCP tool wrappers
- Implementing external service integrations

**Related Skills:** `crystal-dev`, `autobot-test`
