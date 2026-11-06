#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "capture_oracle.hpp"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstddef>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <cstdint>
#include <span>
#include <array>
#include <stdexcept>
#include <string_view>
#include <optional>
#include <chrono>



import telar.runtime.exchange_capture.exchange;

using namespace telar;
using namespace telar::runtime;

class CaptureOracleMemory {
public:
  explicit CaptureOracleMemory(std::size_t fail) noexcept : fail_(fail) {}

  void *allocate(std::size_t bytes, std::size_t alignment) noexcept {
    if (calls++ == fail_) {
      return nullptr;
    }
    auto *pointer = upstream_.allocate(bytes, alignment);
    live += pointer != nullptr;
    return pointer;
  }

  void deallocate(void *pointer, std::size_t bytes, std::size_t alignment) noexcept {
    if (pointer != nullptr) {
      --live;
      upstream_.deallocate(pointer, bytes, alignment);
    }
  }

  std::size_t calls = 0;
  std::size_t live = 0;

private:
  SystemAllocator upstream_;
  std::size_t fail_;
};

using Half = CaptureHalf<CaptureOracleMemory>;
using HalfSlot = std::optional<Owned<Half, CaptureOracleMemory>>;

static void record(CaptureOracleOutput &output, const HalfSlot &slot) noexcept {
  output.integer(slot.has_value());
  if (!slot) {
    return;
  }
  const auto &half = **slot;
  output.integer(half.head.size());
  output.integer(half.body.size());
  output.integer(half.head.capacity());
  output.integer(half.body.capacity());
  output.integer(half.capturedBytes());
  output.integer(half.head.truncated);
  output.integer(half.body.truncated);
  output.integer(half.truncation.part);
  output.integer(half.truncation.exchange);
  output.integer(half.truncation.total);
  output.integer(static_cast<std::uint64_t>(half.outcome));
  output.integer(half.finished_at_ms);
}

static bool apply(Half &half, const CaptureOperation &operation) noexcept {
  const std::string_view bytes{operation.bytes, operation.length};
  if (operation.kind >= 2 && operation.kind <= 5) {
    return half.append(static_cast<CapturePart>(operation.kind - 2), bytes);
  }
  switch (operation.kind) {
  case 6:
    half.appendHead(bytes);
    break;
  case 7:
    half.head.reset();
    break;
  case 8:
    half.body.reset();
    break;
  case 9:
    half.setMethod(bytes);
    break;
  case 10:
    half.setTarget(bytes);
    break;
  case 11:
    half.setEncoding(bytes);
    break;
  case 12:
    half.finish(static_cast<CaptureOutcome>(operation.length % 3), operation.length);
    break;
  }
  return false;
}

extern "C" void capture(const CaptureOracleInput *input, CaptureOracleResult *result) {
  *result = {};
  CaptureOracleMemory memory{input->fail_allocation};
  CaptureQuota quota{input->total_limit};
  const ProxyCaptureLimits limits{.part_bytes = input->part_limit, .exchange_bytes = input->exchange_limit, .total_bytes = input->total_limit, .enabled = input->enabled != 0};
  std::array<HalfSlot, 4> halves;
  CaptureOracleOutput output{*input, *result};

  for (const auto &operation : std::span{input->operations, input->count}) {
    auto &slot = halves[operation.slot % halves.size()];
    bool accepted = false;
    if (operation.kind <= 1) {
      slot.reset();
      if (limits.enabled && operation.length <= Half::maximum_host_bytes) {
        try {
          slot.emplace(makeOwned<Half>(memory, memory, quota, limits, CaptureStart{.side = static_cast<CaptureSide>(operation.kind), .host = {operation.bytes, operation.length}}));
        } catch (const std::bad_alloc &) {
        }
      }
    } else if (operation.kind == 13) {
      slot.reset();
    } else if (slot) {
      accepted = apply(**slot, operation);
    }
    output.integer(accepted);
    output.integer(quota.used());
    record(output, slot);
  }

  for (auto &slot : halves) {
    if (slot) {
      const auto &half = **slot;
      output.text(half.host());
      output.text(half.method());
      output.text(half.target());
      output.text(half.encoding());
      output.bytes(half.head.bytes());
      output.bytes(half.body.bytes());
      slot.reset();
    }
  }
  result->allocation_calls = memory.calls;
  result->retained_allocations = memory.live;
  result->retained_quota = quota.used();
}

extern "C" std::uint64_t batch(const CaptureOracleInput *input, std::size_t iterations) {
  std::uint64_t checksum = 0;
  for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
    CaptureOracleResult result;
    capture(input, &result);
    checksum += result.length + result.allocation_calls;
  }
  return checksum;
}
