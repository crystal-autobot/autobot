require "json"
require "../src/autobot/version"
require "../src/autobot/providers/provider"
require "../src/autobot/providers/types"
require "../src/autobot/providers/registry"
require "../src/autobot/providers/http_provider"
require "../src/autobot/providers/gemini_provider"
require "../src/autobot/constants"

api_key = ENV["GEMINI_API_KEY"]?
if !api_key || api_key.empty?
  puts "Please set GEMINI_API_KEY environment variable"
  exit 1
end

provider = Autobot::Providers::GeminiProvider.new(
  api_key: api_key,
  model: "gemini-3.5-flash"
)

messages = [
  {
    "role" => JSON::Any.new(Autobot::Constants::ROLE_SYSTEM),
    "content" => JSON::Any.new("You are a helpful assistant. " * 500) # Roughly 2500 tokens
  },
  {
    "role" => JSON::Any.new(Autobot::Constants::ROLE_USER),
    "content" => JSON::Any.new("Hello, how are you?")
  }
]

puts "--- First Request (Cache Miss/Creation) ---"
start_time = Time.instant
response1 = provider.chat(messages: messages)
duration1 = Time.instant - start_time

puts "Response received in #{duration1.total_seconds.round(2)}s"
puts "Usage:"
puts "  Prompt tokens: #{response1.usage.prompt_tokens}"
puts "  Completion tokens: #{response1.usage.completion_tokens}"
puts "  Total tokens: #{response1.usage.total_tokens}"
puts "  Cached creation tokens: #{response1.usage.cache_creation_tokens}"
puts "  Cached read tokens: #{response1.usage.cache_read_tokens}"
puts "\n--- Second Request (Cache Hit) ---"
start_time = Time.instant
response2 = provider.chat(messages: messages)
duration2 = Time.instant - start_time

puts "Response received in #{duration2.total_seconds.round(2)}s"
puts "Usage:"
puts "  Prompt tokens: #{response2.usage.prompt_tokens}"
puts "  Completion tokens: #{response2.usage.completion_tokens}"
puts "  Total tokens: #{response2.usage.total_tokens}"
puts "  Cached creation tokens: #{response2.usage.cache_creation_tokens}"
puts "  Cached read tokens: #{response2.usage.cache_read_tokens}"
