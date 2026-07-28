require "../../spec_helper"
require "../../../src/autobot/tools/blocked_address"

private LOCALHOST      = Autobot::Tools::BlockedAddress::LOCALHOST_REASON
private PRIVATE_RANGE  = Autobot::Tools::BlockedAddress::PRIVATE_REASON
private CLOUD_METADATA = Autobot::Tools::BlockedAddress::CLOUD_METADATA_REASON
private LINK_LOCAL     = Autobot::Tools::BlockedAddress::LINK_LOCAL_REASON
private UNRECOGNIZED   = Autobot::Tools::BlockedAddress::UNRECOGNIZED_REASON

private def reason_for(ip : String) : String?
  Autobot::Tools::BlockedAddress.reason_for(ip)
end

describe Autobot::Tools::BlockedAddress do
  describe ".reason_for" do
    it "blocks loopback addresses in every notation" do
      %w[127.0.0.1 127.1.2.3 ::1 ::ffff:127.0.0.1].each do |ip|
        reason_for(ip).should eq(LOCALHOST)
      end
    end

    it "blocks unspecified addresses" do
      %w[0.0.0.0 ::].each do |ip|
        reason_for(ip).should eq(LOCALHOST)
      end
    end

    it "blocks RFC 1918 and unique local ranges" do
      %w[10.0.0.1 192.168.1.1 172.16.0.1 172.31.255.255 fc00::1 fd12:3456::1].each do |ip|
        reason_for(ip).should eq(PRIVATE_RANGE)
      end
    end

    it "blocks private ranges wrapped as IPv4-mapped IPv6" do
      %w[::ffff:10.0.0.1 ::ffff:192.168.1.1 ::ffff:172.16.0.1].each do |ip|
        reason_for(ip).should eq(PRIVATE_RANGE)
      end
    end

    it "blocks link-local ranges" do
      %w[169.254.1.1 fe80::1 ::ffff:169.254.1.1].each do |ip|
        reason_for(ip).should eq(LINK_LOCAL)
      end
    end

    it "blocks the whole fe80::/10 range, not just the fe80: prefix" do
      %w[fe90::1 febf::1].each do |ip|
        reason_for(ip).should eq(LINK_LOCAL)
      end
    end

    it "blocks cloud metadata endpoints ahead of their enclosing ranges" do
      %w[169.254.169.254 fd00:ec2::254 ::ffff:169.254.169.254].each do |ip|
        reason_for(ip).should eq(CLOUD_METADATA)
      end
    end

    it "blocks mapped addresses regardless of prefix casing" do
      reason_for("::FFFF:10.0.0.1").should eq(PRIVATE_RANGE)
    end

    it "blocks addresses it cannot parse" do
      %w[not-an-ip 999.999.999.999].each do |ip|
        reason_for(ip).should eq(UNRECOGNIZED)
      end
    end

    it "allows public addresses" do
      %w[8.8.8.8 1.1.1.1 2001:4860:4860::8888 ::ffff:8.8.8.8].each do |ip|
        reason_for(ip).should be_nil
      end
    end

    it "allows addresses just outside the 172.16.0.0/12 range" do
      %w[172.15.0.1 172.32.0.1].each do |ip|
        reason_for(ip).should be_nil
      end
    end
  end
end
