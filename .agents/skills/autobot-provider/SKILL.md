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
   - Add a new `ProviderSpec` to the `PROVIDERS` list in `src/autobot/providers/registry.cr`.
   - Ensure keywords and API URL are correctly specified.

3. **Add configuration schema**:
   - Update `src/autobot/config/schema.cr` with provider config if needed.
   - Most HTTP providers work automatically if they follow OpenAI compatibility.

4. **Create tests**:
   - `spec/autobot/providers/<name>_provider_spec.cr`
   - Test provider registration in `registry_spec.cr`.
   - Test API integration (mocked).

5. **Add documentation**:
   - `docs/<name>.md` - Provider setup guide.
   - Update `docs/providers.md` - Add to provider comparison.

### Provider Implementation Template

```crystal
# src/autobot/providers/<name>_provider.cr
module Autobot
  module Providers
    class <Name>Provider < HttpProvider
      def initialize(
        api_key : String,
        api_base : String? = nil,
        model : String = "default-model",
        extra_headers = {} of String => String,
        provider_name : String? = nil
      )
        super(api_key, api_base, model, extra_headers, provider_name)
      end

      def chat(
        messages : Array(Hash(String, JSON::Any)),
        tools : Array(Hash(String, JSON::Any))? = nil,
        model : String? = nil,
        max_tokens : Int32 = DEFAULT_MAX_TOKENS,
        temperature : Float64 = DEFAULT_TEMPERATURE
      ) : Response
        # Implement custom logic or call super for OpenAI-compatible
        super
      end
    end
  end
end
```

### ProviderSpec Registration

Add to `PROVIDERS` in `src/autobot/providers/registry.cr`:

```crystal
ProviderSpec.new(
  name: "<name>",
  keywords: ["<keyword1>", "<keyword2>"],
  display_name: "<Display Name>",
  api_url: "https://api.<provider>.com/v1/chat/completions",
)
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
