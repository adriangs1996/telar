#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <limits>
#include <span>
#include "telar_base/memory/allocator.hpp"
#include <cstdint>
#include <cstring>
#include <cstddef>
#include <exception>
#include <charconv>
#include <optional>
#include <string_view>
#include <stdexcept>
#include "telar_base/text/utf8.hpp"



import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;

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
    auto *pointer = local.allocate(8, 1);
    require(pointer == buffer.data());
    local.deallocate(pointer, 8, 1);
    require(budget.liveBytes() == 0);

    telar::CAllocationBlocks blocks{budget};
    auto *block = blocks.allocateZeroed(4, 1);
    require(block != nullptr && static_cast<unsigned char *>(block)[0] == 0);
    blocks.release(block);
    require(budget.liveBytes() == 0);
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
    } catch (const telar::JsonError &) {
      invalid_utf8 = true;
    }
    require(invalid_utf8);

    for (const auto invalid : {"{", "[1,]", "true false", "01"}) {
      bool rejected = false;
      try {
        telar::runtime::JsonValue::parse(invalid);
      } catch (const telar::JsonError &error) {
        rejected = true;
        require(std::string_view{error.what()} == "Invalid JSON record");
      }
      require(rejected);
    }
  }

}

int main() {
  testMemory();
  testRetainedStream();
  testLimits();
  testJson();
}
