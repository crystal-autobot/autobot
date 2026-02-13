module Autobot
  VERSION = "0.1.0"

  # Build info
  CRYSTAL_VERSION = {{ Crystal::VERSION }}
  BUILD_DATE      = {{ `date -u +%Y-%m-%d`.stringify.strip }}
end
