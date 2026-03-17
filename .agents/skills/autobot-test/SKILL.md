---
name: autobot-test
description: Testing guidelines for Autobot with AAA pattern and Crystal spec best practices
tags:
  - test
  - spec
  - quality
metadata:
  author: renich
  scope: development
---

## Testing Standards

### AAA Pattern

Structure all tests with Arrange-Act-Assert and require the spec helper:

```crystal
require "../spec_helper"

describe "MyFeature" do
  it "does something expected" do
    # Arrange
    tool = Autobot::Tools::MyTool.new
    params = {"key" => JSON::Any.new("value")}
    
    # Act
    result = tool.execute(params)
    
    # Assert
    result.success?.should be_true
    result.content.should contain("expected")
  end
end
```

### Test File Organization

Mirror source structure:
```
spec/
├── autobot/
│   ├── providers/
│   │   ├── http_provider_spec.cr
│   │   └── registry_spec.cr
│   ├── tools/
│   │   ├── web_spec.cr
│   │   └── exec_spec.cr
│   └── config/
│       └── schema_spec.cr
├── spec_helper.cr
└── security_spec.cr
```

### Running Tests

```bash
# Run all tests
crystal spec

# Run specific file
crystal spec spec/autobot/tools/web_spec.cr

# Run specific test by line number
crystal spec spec/autobot/tools/web_spec.cr:42

# Run with verbose output
crystal spec -v

# Run with color (default)
crystal spec --color
```

### Mocking External Services

**HTTP Provider Mocking:**
```crystal
class MockHttpProvider < Autobot::Providers::HttpProvider
  property responses = [] of HTTP::Client::Response
  property call_count = 0

  def post(path : String, body : Hash) : HTTP::Client::Response
    @call_count += 1
    responses.shift? || HTTP::Client::Response.new(500, body: "{}").tap { |r| r.consume_body_io }
  end
end
```

**Tool Execution Mocking:**
```crystal
# Use dependency injection or monkey-patch for tests
class TestableExecTool < Autobot::Tools::ExecTool
  property captured_commands = [] of String

  def execute_system_command(cmd)
    @captured_commands << cmd
    {output: "mock output", exit_code: 0}
  end
end
```

### Testing Error Conditions

Always test error paths:
```crystal
it "handles missing parameters" do
  tool = Autobot::Tools::MyTool.new
  result = tool.execute({} of String => JSON::Any)
  
  result.error?.should be_true
  result.content.should contain("missing")
end

it "handles rate limiting" do
  limiter = Autobot::Tools::RateLimiter.new(
    per_tool_limits: {"exec" => Autobot::Tools::RateLimiter::Limit.new(
      max_calls: 1,
      window_seconds: 60
    )}
  )
  
  limiter.record_call("exec", "session")
  error = limiter.check_limit("exec", "session")
  
  error.should_not be_nil
  error.should contain("max 1 calls")
end
```

### Avoiding not_nil!

Use safe nil handling:
```crystal
# Bad
result.content.not_nil!.should contain("text")

# Good
if content = result.content
  content.should contain("text")
else
  fail("Expected content to not be nil")
end

# Also good
content = result.content
content.should_not be_nil
content.should contain("text") if content
```

### Shared Examples

For common test patterns:
```crystal
macro test_provider_interface
  describe "provider interface" do
    it "returns a name" do
      provider.name.should be_a(String)
      provider.name.should_not be_empty
    end

    it "returns a display name" do
      provider.display_name.should be_a(String)
    end
  end
end

# Usage
describe Autobot::Providers::MyProvider do
  provider = Autobot::Providers::MyProvider.new(api_key: "test")
  test_provider_interface
end
```

### Security Testing

Test security constraints explicitly:
```crystal
describe "SSRF protection" do
  it "blocks private IPs" do
    tool = Autobot::Tools::WebFetchTool.new
    
    %w[http://127.0.0.1/secret http://10.0.0.1/].each do |url|
      result = tool.execute({"url" => JSON::Any.new(url)})
      result.access_denied?.should be_true
    end
  end
end
```

### Test Performance

- Keep tests fast (< 1s per test ideally)
- Use `before_each`/`after_each` for setup/teardown
- Avoid real network calls (mock HTTP)
- Avoid real file system operations when possible

### Coverage

Test these scenarios:
- [ ] Happy path (normal operation)
- [ ] Invalid inputs
- [ ] Missing required parameters
- [ ] Error conditions (network, auth, etc.)
- [ ] Edge cases (empty strings, max values, etc.)
- [ ] Security constraints (private IPs, path traversal, etc.)

### Related Files and Examples

**Test Infrastructure:**
- `spec/spec_helper.cr` - Test setup and helpers
- `spec/support/test_helper.cr` - Test utilities

**Example Tests:**
- `spec/autobot/tools/exec_spec.cr` - Tool testing patterns
- `spec/autobot/providers/http_provider_spec.cr` - Provider mocking
- `spec/autobot/config/schema_spec.cr` - Configuration tests

**Mock Patterns:**
- `spec/support/mock_provider.cr` - HTTP provider mocking

## When to Use

Use this skill when:
- Writing new tests
- Debugging test failures
- Refactoring test code
- Setting up test infrastructure
- Reviewing test coverage

**Related Skills:** `crystal-dev`, `autobot-tool`, `autobot-provider`
