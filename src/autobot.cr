require "option_parser"
require "aws-sigv4"
require "./autobot/**"

module Autobot
  # Main CLI entry point
  def self.run
    CLI::Commands.run
  end
end
