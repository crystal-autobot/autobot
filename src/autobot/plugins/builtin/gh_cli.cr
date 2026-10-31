require "../../tools/command_runner"

module Autobot
  module Plugins
    module Builtin
      # Offline probes of the local `gh` install, shared by the validator and doctor.
      module GhCli
        PROBE_TIMEOUT = 10

        record Status, installed : Bool, logged_in : Bool

        class_property override : {Status, String?}? = nil

        def self.status : Status
          override.try { |(status, _)| return status }

          installed = !Process.find_executable("gh").nil?
          Status.new(installed, installed && run(["auth", "token"]))
        end

        def self.login : String?
          override.try { |(_, login)| return login }

          result = Tools::CommandRunner.run("gh", ["api", "user", "-q", ".login"], PROBE_TIMEOUT)
          result.success? ? result.stdout.strip.presence : nil
        rescue
          nil
        end

        private def self.run(args : Array(String)) : Bool
          Tools::CommandRunner.run("gh", args, PROBE_TIMEOUT).success?
        rescue
          false
        end
      end
    end
  end
end
