---
name: autobot-provider
description: Add new LLM providers to Autobot with proper integration
tags:
  - provider
  - llm
  - integration
metadata:
  author: renich
  scope: feature-development
---

## Adding a New LLM Provider

### Files to Create/Modify

1. **Create provider implementation**:
   - `src/autobot/providers/<name>_provider.cr`
   - Inherit from `HttpProvider` or implement `Provider` interface

2. **Register provider**:
   - Add to `src/autobot/providers/registry.cr`
   - Update provider loading logic

3. **Add configuration schema**:
   - Update `src/autobot/config/schema.cr` with provider config
   - Add API key and optional settings

4. **Create tests**:
   - `spec/autobot/providers/<name>_provider_spec.cr`
   - Test provider registration
   - Test configuration validation
   - Test API integration (mocked)

5. **Add documentation**:
   - `docs/<name>.md` - Provider setup guide
   - Update `docs/providers.md` - Add to provider comparison
   - Update `docs/index.md` - Add to provider list

6. **Update CLI setup**:
   - Modify `src/autobot/cli/interactive_setup.cr` for provider selection
   - Update `src/autobot/cli/config_generator.cr` for provider templates

### Provider Implementation Template

```crystal
# src/autobot/providers/<name>_provider.cr
module Autobot
  module Providers
    class <Name>Provider < HttpProvider
      def initialize(api_key : String, model : String = "default-model")
        super(api_key: api_key, model: model)
        @base_uri = URI.parse("https://api.provider.com/v1")
      end

      def name : String
        "<name>"
      end

      def display_name : String
        "<Display Name>"
      end

      def chat(messages : Array(Hash(String, JSON::Any)), **options) : ChatResponse
        # Implement API call
        response = post("/chat/completions", build_payload(messages, options))
        parse_response(response)
      end

      private def build_payload(messages, options)
        {
          model: @model,
          messages: messages,
          max_tokens: options[:max_tokens]?,
          temperature: options[:temperature]?,
        }.compact
      end

      private def parse_response(response : HTTP::Client::Response) : ChatResponse
        # Parse JSON and return ChatResponse
        body = JSON.parse(response.body)
        ChatResponse.new(
          content: body["choices"][0]["message"]["content"].as_s,
          finish_reason: body["choices"][0]["finish_reason"].as_s? || "stop",
          tokens_used: body["usage"]["total_tokens"].as_i?
        )
      end
    end
  end
end
```

### Testing Checklist

- [ ] Provider registers correctly in registry
- [ ] Configuration schema validates properly
- [ ] API calls are mocked in tests
- [ ] Error handling works (401, 429, 500 responses)
- [ ] User-Agent handling (if provider requires specific UA)
- [ ] Interactive setup includes new provider

### Documentation Requirements

Each provider doc must include:
- API key acquisition instructions
- Supported models list
- Rate limits and pricing notes
- Special features (if any)
- Example configuration

## When to Use

Use this skill when:
- Adding support for a new LLM service
- Integrating a new AI provider API
- Testing provider implementations
- Updating provider documentation
