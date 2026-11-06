#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cstdint>
#include <span>
#include <cassert>
#include <cstring>
#include <cstddef>
#include "telar_base/memory/fixed_text.hpp"
#include <array>
#include <bit>
#include <optional>
#include "../terminal/ghostty_allocator.hpp"

#include "terminal/ghostty_allocator.hpp"


import telar.base.memory;

using namespace telar;
using namespace telar::runtime;

static void testBufferAllocations() {
  SystemAllocator system;
  BudgetAllocator memory{system, 256};
  alignas(64) std::array<std::byte, 64> storage;
  BufferAllocator buffered{memory, std::span{storage}.subspan(1)};
  ErasingAllocator sensitive{buffered};
  auto *first = static_cast<unsigned char *>(sensitive.allocate(5, 32));
  auto *second = static_cast<unsigned char *>(sensitive.allocate(27, 1));
  check(first != nullptr && reinterpret_cast<std::uintptr_t>(first) % 32 == 0);
  check(second == first + 5 && memory.liveBytes() == 0);
  std::memset(first, 73, 32);
  sensitive.deallocate(first, 5, 32);
  sensitive.deallocate(second, 27, 1);
  check(std::ranges::all_of(std::span{first, 32}, [](auto byte) { return byte == 0; }));

  auto *fallback = sensitive.allocate(128, 16);
  check(fallback != nullptr && memory.liveBytes() == 128);
  check(sensitive.allocate(257, 1) == nullptr);
  std::memset(fallback, 91, 128);
  sensitive.deallocate(fallback, 128, 16);
  check(memory.liveBytes() == 0);

  BufferAllocator empty{memory, {}};
  auto *allocation = empty.allocate(16, 8);
  check(allocation != nullptr && memory.liveBytes() == 16);
  empty.deallocate(allocation, 16, 8);
  check(memory.liveBytes() == 0);
}

static void testSlotIndexes() {
  SlotIndexes<70> indexes;
  for (std::size_t index = 0; index < 70; ++index) {
    check(indexes.firstUnused() == index);
    indexes.insert(index);
  }
  check(!indexes.firstUnused());
  std::size_t visited = 0;
  indexes.forEach([&](std::size_t index) {
    check(index == visited++);
    indexes.erase(index);
  });
  check(visited == 70 && indexes.firstUnused() == 0);
  for (const auto index : {0, 63, 64, 69}) {
    indexes.insert(index);
  }
  const std::array<std::size_t, 4> expected{0, 63, 64, 69};
  visited = 0;
  indexes.forEach([&](std::size_t index) { check(index == expected[visited++]); });
  check(visited == expected.size() && indexes.firstUnused() == 1);
}

static void testFixedText() {
  FixedText<8> text;
  check(text.view().empty());

  text.assign("abcdefgh");
  auto copied = text;
  text.assign(text.view().substr(2, 4));
  check(text.view() == "cdef");
  check(copied.view() == "abcdefgh");

  copied = text;
  check(copied.view() == "cdef");

  bool rejected = false;
  try {
    text.assign("too large");
  } catch (const std::length_error &) {
    rejected = true;
  }
  check(rejected);
  check(text.view() == "cdef");

  text.assign({});
  copied = text;
  check(copied.view().empty());

  std::optional<FixedText<4096>> absent;
  auto transferred = absent;
  check(!transferred);
  absent.emplace().assign("/tmp");
  transferred = absent;
  check(transferred->view() == "/tmp");
  absent.reset();
  transferred = absent;
  check(!transferred);
}

static void testSensitiveErasure() {
  std::array<unsigned char, 128 * 1024 + 2> bytes;
  for (const std::size_t length : {0, 1, 7, 16, 31, 32, 33, 1024, 128 * 1024}) {
    bytes.fill(73);
    eraseSensitive(bytes.data() + 1, length);
    check(bytes.front() == 73 && bytes[length + 1] == 73);
    check(std::all_of(bytes.begin() + 1, bytes.begin() + 1 + length, [](auto value) { return value == 0; }));
  }
  eraseSensitive(nullptr, 0);
}

void testMemory() {
  testBufferAllocations();
  testSlotIndexes();
  testFixedText();
  testSensitiveErasure();

  SystemAllocator system;
  BudgetAllocator memory{system, 1024};

  {
    Vector<std::uint64_t, decltype(memory)> numbers{AllocatorRef<std::uint64_t, decltype(memory)>{memory}};
    numbers.resize(16, 42);
    check(memory.liveBytes() == 16 * sizeof(std::uint64_t));
    check(memory.allocate(1024, 1) == nullptr);
    check(memory.failures() == 1);
  }

  check(memory.liveBytes() == 0);
  {
    BudgetAllocator limited{system, 8};
    ByteQueue queue{limited, 16};
    const std::array<std::uint8_t, 4> bytes{1, 2, 3, 4};
    queue.reserve(8);
    queue.append(bytes);
    queue.consume(2);
    bool rejected = false;
    try {
      queue.appendUninitialized(7);
    } catch (const std::bad_alloc &) {
      rejected = true;
    }
    check(rejected);
    check(queue.size() == 2);
    check(queue.readable()[0] == 3 && queue.readable()[1] == 4);
    check(limited.liveBytes() == 8);
  }

  auto *aligned = memory.allocate(128, 128);
  check(aligned != nullptr);
  check(reinterpret_cast<std::uintptr_t>(aligned) % 128 == 0);
  memory.deallocate(aligned, 128, 128);

  GhosttyAllocatorBridge bridge{memory};
  auto *ghostty_bytes = ghostty_alloc(bridge.get(), 100);
  check(ghostty_bytes != nullptr);
  check(memory.liveBytes() == 100);
  ghostty_free(bridge.get(), ghostty_bytes, 100);
  check(memory.liveBytes() == 0);

  {
    ByteQueue queue{memory, 64};
    const std::array<std::uint8_t, 4> bytes{1, 2, 3, 4};
    queue.reserve(64);
    queue.append(bytes);
    queue.consume(3);
    queue.append(bytes);
    check(queue.size() == 5);
    check(queue.readable()[0] == 4);
    queue.consume(5);
    check(queue.empty());

    bool rejected = false;
    try {
      queue.appendUninitialized(65);
    } catch (const std::bad_alloc &) {
      rejected = true;
    }

    check(rejected);
    check(queue.empty());
  }

  check(memory.liveBytes() == 0);
}
