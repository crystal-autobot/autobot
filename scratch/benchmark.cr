require "../src/autobot/providers/provider"
require "../src/autobot/providers/types"
require "../src/autobot/providers/registry"
require "../src/autobot/providers/http_provider"
require "../src/autobot/constants"

api_key = ENV["GEMINI_API_KEY"]?
if !api_key || api_key.empty?
  puts "Please set GEMINI_API_KEY environment variable"
  exit 1
end

provider = Autobot::Providers::HttpProvider.new(
  api_key: api_key,
  model: "gemini/gemini-2.5-flash"
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

puts "Sending request via HttpProvider (OpenAI wrapper)..."
start_time = Time.monotonic
response = provider.chat(messages: messages)
duration = Time.monotonic - start_time

puts "Response received in #{duration.total_seconds.round(2)}s"
puts "Content: #{response.content}"
puts "Usage:"
puts "  Prompt tokens: #{response.usage.prompt_tokens}"
puts "  Completion tokens: #{response.usage.completion_tokens}"
puts "  Total tokens: #{response.usage.total_tokens}"
puts "  Cached creation tokens: #{response.usage.cache_creation_tokens}"
puts "  Cached read tokens: #{response.usage.cache_read_tokens}"
