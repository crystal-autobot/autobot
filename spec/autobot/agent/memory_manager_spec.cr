require "../../spec_helper"

describe Autobot::Agent::MemoryManager do
  describe "constants" do
    it "has proper constant values for memory management" do
      Autobot::Agent::MemoryManager::DISABLED_MEMORY_WINDOW.should eq(0)
      Autobot::Agent::MemoryManager::MAX_MESSAGES_WITHOUT_CONSOLIDATION.should eq(10)
      Autobot::Agent::MemoryManager::MIN_KEEP_COUNT.should eq(2)
      Autobot::Agent::MemoryManager::MAX_KEEP_COUNT.should eq(10)
    end
  end
end
