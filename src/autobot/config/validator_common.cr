module Autobot::Config
  # Common types and utilities for validators
  module ValidatorCommon
    enum Severity
      Info
      Warning
      Error
    end

    record Issue,
      severity : Severity,
      message : String
  end
end
