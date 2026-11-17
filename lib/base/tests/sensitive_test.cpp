#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.testing.erasure_checking_allocator;
import telar.base.memory.allocators;
import telar.base.memory.sensitive;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Secrets live in fixed buffers: text past the capacity is refused and leaves the text as it was.
  void testSensitiveTextCapacity() {
    SensitiveText<4> text;
    bool refused = false;

    text.append("abc");
    try {
      text.append("de");
    } catch (const std::length_error&) {
      refused = true;
    }

    check(refused);
    check(text.view() == "abc");
    text.append("d");
    check(text.view() == "abcd");
  }

  // Captured traffic is held in SensitiveAllocations: their bytes reach the upstream allocator
  // erased, when one is destroyed and when a move assignment replaces the block it held.
  void testSensitiveAllocationErases() {
    ErasureCheckingAllocator upstream;
    MemoryAdapter adapter{upstream};
    Memory& memory = adapter;

    {
      SensitiveAllocation<Memory> first{memory, 64};
      SensitiveAllocation<Memory> second{memory, 32};

      std::ranges::fill(first.bytes(), std::uint8_t{0x5a});
      std::ranges::fill(second.bytes(), std::uint8_t{0x5a});
      first = std::move(second);
      check(first.bytes().size() == 32);
    }

    check(upstream.budget.liveBytes() == 0);
  }

  const telar::testing::Case case_sensitive_text{"sensitive.text_capacity", testSensitiveTextCapacity};
  const telar::testing::Case case_sensitive_allocation{"sensitive.allocation_erases", testSensitiveAllocationErases};

}
