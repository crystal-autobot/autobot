require "socket"

module Autobot
  module Tools
    # Classifies IP addresses against ranges that must not be reachable through user-supplied URLs.
    module BlockedAddress
      IPV4_MAPPED_PREFIX = "::ffff:"

      CLOUD_METADATA_ADDRESSES = {"169.254.169.254", "fd00:ec2::254"}

      LOCALHOST_REASON      = "Access to localhost is blocked"
      PRIVATE_REASON        = "Access to private IP addresses is blocked"
      CLOUD_METADATA_REASON = "Access to cloud metadata endpoints is blocked"
      LINK_LOCAL_REASON     = "Access to link-local addresses is blocked"
      UNRECOGNIZED_REASON   = "Access to unrecognized addresses is blocked"

      def self.reason_for(ip : String) : String?
        address = parse(ip)
        return UNRECOGNIZED_REASON unless address

        # Metadata endpoints sit inside the link-local and private ranges.
        return CLOUD_METADATA_REASON if CLOUD_METADATA_ADDRESSES.includes?(address.address)
        return LOCALHOST_REASON if address.loopback? || address.unspecified?
        return PRIVATE_REASON if address.private?
        return LINK_LOCAL_REASON if address.link_local?

        nil
      end

      # Socket::IPAddress unwraps IPv4-mapped IPv6 for #loopback? only, so the embedded IPv4 is classified directly.
      private def self.parse(ip : String) : Socket::IPAddress?
        build(ip.downcase.lchop?(IPV4_MAPPED_PREFIX)) || build(ip)
      end

      private def self.build(ip : String?) : Socket::IPAddress?
        ip ? Socket::IPAddress.new(ip, 0) : nil
      rescue Socket::Error
        nil
      end
    end
  end
end
