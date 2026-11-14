#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>

import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.base.text;
import telar.base.text.json;
import telar.base.text.utf8;

namespace {

  void require(bool condition) {
    if (!condition) {
      throw std::runtime_error{"Base library regression"};
    }
  }

  void testMemory() {
    static_assert(telar::Allocator<telar::SystemAllocator>);
    static_assert(telar::ConcurrentAllocator<telar::SystemAllocator>);
    static_assert(!telar::ConcurrentAllocator<telar::BudgetAllocator<telar::SystemAllocator>>);
    static_assert(!telar::Allocator<int>);

    telar::SystemAllocator system;
    telar::BudgetAllocator budget{system, 256};

    {
      telar::Vector<int, decltype(budget)> values{telar::AllocatorRef<int, decltype(budget)>{budget}};

      values.push_back(42);
      auto value = telar::makeOwned<int>(budget, 7);

      require(values.front() == 42 && *value == 7);
      require(budget.liveBytes() == 2 * sizeof(int));
      require(budget.allocate(256, alignof(int)) == nullptr);
    }

    require(budget.liveBytes() == 0);
    require(budget.failures() == 1);

    std::array<std::byte, 32> buffer{};
    telar::BufferAllocator local{budget, buffer};
    auto* pointer = local.allocate(8, 1);

    require(pointer == buffer.data());
    local.deallocate(pointer, 8, 1);
    require(budget.liveBytes() == 0);

    telar::CAllocationBlocks blocks{budget};
    auto* block = blocks.allocateZeroed(4, 1);

    require(block != nullptr && static_cast<unsigned char*>(block)[0] == 0);
    blocks.release(block);
    require(budget.liveBytes() == 0);
  }

  // An allocator whose every request fails, as an exhausted system would.
  struct FailingAllocator {
    static constexpr bool thread_safe = true;

    void* allocate(std::size_t, std::size_t) noexcept {
      ++requests;
      return nullptr;
    }

    void deallocate(void*, std::size_t, std::size_t) noexcept {
      ++releases;
    }

    std::size_t requests = 0;
    std::size_t releases = 0;
  };

  // A service boundary that knows only the erased interface.
  bool fill(telar::Memory& memory, std::size_t count) {
    try {
      telar::Vector<int, telar::Memory> values{telar::AllocatorRef<int, telar::Memory>{memory}};

      values.resize(count, 7);
      return values.back() == 7;
    } catch (const std::bad_alloc&) {
      return false;
    }
  }

  void testMemoryInterface() {
    using Budget = telar::BudgetAllocator<telar::SystemAllocator>;
    using Erasing = telar::ErasingAllocator<telar::BufferAllocator<Budget>>;

    static_assert(std::is_abstract_v<telar::Memory>);
    static_assert(!std::is_copy_constructible_v<telar::MemoryAdapter<Budget>>);
    static_assert(telar::Allocator<telar::Memory> && !telar::ConcurrentAllocator<telar::Memory>);
    static_assert(telar::ConcurrentAllocator<telar::ConcurrentMemory>);
    static_assert(std::derived_from<telar::MemoryAdapter<telar::SystemAllocator>, telar::ConcurrentMemory>);
    static_assert(std::derived_from<telar::MemoryAdapter<FailingAllocator>, telar::ConcurrentMemory>);
    static_assert(std::derived_from<telar::MemoryAdapter<Budget>, telar::Memory>);
    static_assert(!std::derived_from<telar::MemoryAdapter<Budget>, telar::ConcurrentMemory>);
    static_assert(std::derived_from<telar::MemoryAdapter<Erasing>, telar::ErasingMemory>);
    static_assert(std::derived_from<telar::MemoryAdapter<telar::RecyclingAllocator<Budget>>, telar::ErasingMemory>);
    // A concurrent allocator that erases still adapts to ErasingMemory, never to ConcurrentMemory.
    static_assert(std::derived_from<telar::MemoryAdapter<telar::ErasingAllocator<telar::SystemAllocator>>, telar::ErasingMemory>);

    FailingAllocator failing;
    telar::MemoryAdapter refused{failing};
    telar::Memory& exhausted = refused;

    require(exhausted.allocate(16, 8) == nullptr);
    require(!fill(exhausted, 4));

    bool thrown = false;

    try {
      static_cast<void>(telar::makeOwned<int>(exhausted, 7));
    } catch (const std::bad_alloc&) {
      thrown = true;
    }

    require(thrown && failing.requests == 3 && failing.releases == 0);

    telar::SystemAllocator system;
    Budget budget{system, 64};
    telar::MemoryAdapter budgeted{budget};
    telar::Memory& memory = budgeted;

    require(fill(memory, 16));
    require(!fill(memory, 17));
    require(budget.liveBytes() == 0 && budget.failures() == 1);

    {
      const int seven = 7;
      auto value = telar::makeOwned<int>(memory, seven);
      auto* block = memory.allocate(64 - sizeof(int), alignof(int));

      require(*value == 7 && block != nullptr && budget.liveBytes() == 64);
      require(memory.allocate(1, 1) == nullptr && budget.failures() == 2);
      memory.deallocate(block, 64 - sizeof(int), alignof(int));
    }

    require(budget.liveBytes() == 0);

    alignas(16) std::array<std::byte, 32> buffer{};
    telar::BufferAllocator<Budget> buffered{budget, buffer};
    Erasing erasing{buffered};
    telar::MemoryAdapter sensitive{erasing};
    telar::ErasingMemory& secrets = sensitive;
    auto* secret = static_cast<std::byte*>(secrets.allocate(16, 16));

    require(secret == buffer.data());
    std::memset(secret, 0x5a, 16);
    secrets.deallocate(secret, 16, 16);
    require(std::ranges::all_of(buffer, [](std::byte byte) {
      return byte == std::byte{0};
    }));
  }

  void testRetainedStream() {
    telar::SystemAllocator memory;
    telar::runtime::RetainedStream stream{memory, 4};
    const std::array<std::uint8_t, 3> first{1, 2, 3};
    const std::array<std::uint8_t, 2> second{4, 5};

    stream.append(first);
    stream.append(second);
    std::array<std::uint8_t, 4> output{};

    require(stream.read(1, output).size() == output.size());
    require((output == std::array<std::uint8_t, 4>{2, 3, 4, 5}));
    require(stream.retainedOffset() == 1 && stream.total() == 5);
    require(stream.read(0, output).empty());
  }

  void testLimits() {
    telar::runtime::LimitLedger ledger;
    const telar::LimitReach reach{"test.bytes", "bytes", 16, 17, "test"};
    const auto recorded = ledger.record(reach, 2);

    require(recorded.show && recorded.row.hits == 2);
    require(recorded.row.reach().name == reach.name);
    require(recorded.row.reach().requested == reach.requested);
    require(ledger.rows().size() == 1);
  }

  void testJson() {
    telar::SystemAllocator memory;
    telar::String<telar::SystemAllocator> text{telar::AllocatorRef<char, telar::SystemAllocator>{memory}};
    const auto value = telar::runtime::JsonValue::parse(R"({"name":"hello\nworld"})");

    value.field("name")->string(text);
    require(text == "hello\nworld");
    require(telar::inspectUtf8("hello") == telar::Utf8Validation::valid);
    require(telar::inspectUtf8("\xc3\xa9") == telar::Utf8Validation::valid);
    require(telar::inspectUtf8(std::string_view{"\xff", 1}) == telar::Utf8Validation::invalid_leading);
    bool invalid_utf8 = false;

    try {
      telar::runtime::JsonNode<telar::SystemAllocator>::parse(memory, std::string_view{"\"\xff\"", 3});
    } catch (const telar::JsonError&) {
      invalid_utf8 = true;
    }

    require(invalid_utf8);

    for (const auto invalid : {"{", "[1,]", "true false", "01"}) {
      bool rejected = false;

      try {
        telar::runtime::JsonValue::parse(invalid);
      } catch (const telar::JsonError& error) {
        rejected = true;
        require(std::string_view{error.what()} == "Invalid JSON record");
      }

      require(rejected);
    }
  }

  std::string paste(std::string_view text, bool bracketed) {
    std::string encoded;

    telar::BracketedPaste::encode(text, bracketed, [&](std::string_view piece) {
      encoded.append(piece);
    });

    require(encoded.size() == telar::BracketedPaste::size(text.size(), bracketed));
    return encoded;
  }

  void testNumbers() {
    using telar::runtime::NumberError;
    using telar::runtime::parseExact;
    using telar::runtime::unsignedDecimal;
    using telar::runtime::unsignedNumber;

    require(unsignedDecimal<std::uint16_t>("65_535") == 65535 && !unsignedDecimal<std::uint16_t>("65536"));
    require(!unsignedDecimal<std::uint8_t>("_1") && !unsignedDecimal<std::uint8_t>("1_") && !unsignedDecimal<std::uint8_t>("") && !unsignedDecimal<std::uint8_t>("0x1"));
    require(unsignedNumber<std::uint32_t>("1F_ff", 0x1fffff, 16) == 0x1fff && unsignedNumber<std::uint32_t>("200000", 0x1fffff, 16).error() == NumberError::overflow);
    require(unsignedNumber<std::uint8_t>("9x").error() == NumberError::invalid_character && unsignedNumber<std::uint8_t>("999x").error() == NumberError::overflow);
    require(unsignedNumber<std::uint8_t>("a", 255, 10).error() == NumberError::invalid_character);
    require(parseExact<std::uint16_t>("8080") == 8080 && !parseExact<std::uint16_t>("8080 ") && !parseExact<std::uint16_t>("") && !parseExact<std::uint16_t>("70000"));
    require(parseExact<int>("-7") == -7 && parseExact<unsigned>("ff", 16) == 255u);
  }

  void testBracketedPaste() {
    require(paste("ls\n", false) == "ls\n");
    require(paste("ls\n", true) == "\x1b[200~ls\n\x1b[201~");
    require(paste("", true) == "\x1b[200~\x1b[201~");
    // A terminator in the text cannot close the frame early and run its tail.
    require(paste("a\x1b[201~rm -rf ~\n", true) == "\x1b[200~a [201~rm -rf ~\n\x1b[201~");
    require(paste("\x1b[201~\x1b[201~", true) == "\x1b[200~ [201~ [201~\x1b[201~");
    require(paste("\x1b[200~x\x1b", true) == "\x1b[200~\x1b[200~x\x1b\x1b[201~");
  }

}

int main() {
  testMemory();
  testMemoryInterface();
  testBracketedPaste();
  testNumbers();
  testRetainedStream();
  testLimits();
  testJson();
}
