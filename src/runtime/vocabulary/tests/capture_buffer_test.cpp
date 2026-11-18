import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.vocabulary.exchange;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A buffer whose limit is not a power of two grows to that limit and no further, so the quota
  // shared by every capture is not charged past what the buffer may hold.
  void testLimitNotPowerOfTwo() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    CaptureQuota quota{4096};
    constexpr std::size_t limit = 1000;
    constexpr ds::Array<std::uint8_t, 1> byte{'x'};

    {
      CaptureBuffer buffer{memory, quota, limit};

      for (std::size_t index = 0; index < limit; ++index) {
        check(buffer.append(byte) == 1);
      }

      check(buffer.size() == limit && !buffer.truncated && quota.used() <= limit);

      check(buffer.append(byte) == 0 && buffer.truncated && buffer.size() == limit);
    }

    check(quota.used() == 0);
  }

  const telar::testing::Case case_limit_not_power_of_two{"capture_vocabulary.limit_not_power_of_two", testLimitNotPowerOfTwo};

}
