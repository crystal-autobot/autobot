---
name: autobot-tool
description: Create new tools for Autobot agent with proper schema and safety
tags:
  - tool
  - mcp
  - integration
metadata:
  author: renich
  scope: feature-development
---

## Creating a New Tool

### Files to Create/Modify

1. **Create tool implementation**:
   - `src/autobot/tools/<name>_tool.cr`
   - Inherit from `Tool` base class
   - Implement `Tool` interface

2. **Register tool**:
   - Tools are registered at runtime in the agent loop or CLI gateway
   - See `src/autobot/cli/gateway.cr` for examples of tool registration
   - Tools are instantiated and added to the registry

3. **Add configuration** (if configurable):
   - Update `src/autobot/config/schema.cr`
   - Add tool-specific settings

4. **Create tests**:
   - `spec/autobot/tools/<name>_tool_spec.cr`
   - Test all tool functionality
   - Test error handling
   - Test safety guards

5. **Add documentation** (if user-facing):
   - Update relevant docs in `docs/`

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
        param2 = params["param2"]?.try(&.as_i) || default_value

        # Validate inputs
        if error = validate_input(param1)
          return ToolResult.error(error)
        end

        # Execute tool logic
        begin
          result = perform_action(param1, param2)
          ToolResult.success(result)
        rescue ex
          ToolResult.error("Tool execution failed: #{ex.message}")
        end
      end

      private def validate_input(param1 : String) : String?
        # Return error message if invalid, nil if valid
        nil
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

**Example URL validation:**
```crystal
private def validate_url(url_str : String) : String?
  uri = URI.parse(url_str)
  
  # Check scheme
  unless uri.scheme.in?("http", "https")
    return "Only HTTP/HTTPS URLs allowed"
  end

  # Check for private IPs
  if uri.host
    begin
      ip = IPAddress.parse(uri.host)
      if ip.private? || ip.loopback?
        return "Private IP addresses not allowed"
      end
    rescue
      # Not an IP, proceed
    end
  end

  nil
end
```

### Rate Limiting

Tools should respect rate limits:
- Implement in `check_limit` if tool makes external calls
- Configure limits in `config.yml`
- Return user-friendly error messages when rate limited

### Testing Requirements

- [ ] Tool executes successfully with valid params
- [ ] Tool handles invalid params gracefully
- [ ] Tool enforces safety constraints
- [ ] Tool respects rate limits
- [ ] Error messages are clear and actionable
- [ ] ToolResult types used correctly (success/error/access_denied)

### Related Files and Examples

**Base Classes:**
- `src/autobot/tools/base.cr` - Tool abstract class and ToolSchema
- `src/autobot/tools/result.cr` - ToolResult definition

**Working Examples:**
- `src/autobot/tools/exec.cr` - Command execution (complex validation)
- `src/autobot/tools/web.cr` - HTTP fetching (URL validation example)
- `src/autobot/tools/filesystem.cr` - File operations

**Registration:**
- `src/autobot/tools/registry.cr` - Tool registry
- `src/autobot/cli/gateway.cr` - Tool instantiation examples

**Tests:**
- `spec/autobot/tools/exec_spec.cr` - Exec tool tests
- `spec/autobot/tools/web_spec.cr` - Web tool tests

## When to Use

Use this skill when:
- Creating a new tool for the agent
- Adding MCP tool wrappers
- Implementing external service integrations
- Adding utility tools (file operations, web requests, etc.)

**Related Skills:** `crystal-dev`, `autobot-test`
