module Autobot
  # Version from shard.yml (single source of truth)
  VERSION = {{ `shards version #{__DIR__}/../..`.stringify.strip }}

  # Build info
  CRYSTAL_VERSION = {{ Crystal::VERSION }}
  BUILD_DATE      = {{ `date -u +%Y-%m-%d`.stringify.strip }}

  # Website
  WEBSITE_URL = "https://crystal-autobot.github.io/autobot"
end
