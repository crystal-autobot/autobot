require "option_parser"
require "awscr-signer"
require "./autobot/**"

module Autobot
  # Main CLI entry point
  def self.run
    CLI::Commands.run
  end
end
