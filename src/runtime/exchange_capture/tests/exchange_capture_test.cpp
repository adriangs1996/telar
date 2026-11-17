#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.exchange_capture.pipeline;
import telar.config.runtime;
import telar.runtime.vocabulary.exchange;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testCaptureGrowthAndErasure() {
    class InspectMemory {
    public:
      void* allocate(std::size_t bytes, std::size_t alignment) noexcept {
        return upstream.allocate(bytes, alignment);
      }

      void deallocate(void* pointer, std::size_t bytes, std::size_t alignment) noexcept {
        const auto* storage = static_cast<const std::uint8_t*>(pointer);

        check(std::all_of(storage, storage + bytes, [](auto byte) {
          return byte == 0;
        }));

        upstream.deallocate(pointer, bytes, alignment);
      }

      SystemAllocator upstream;
    } inspected;

    SynchronizedAllocator synchronized{inspected};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    CaptureQuota quota{600};
    const std::array<std::uint8_t, 300> fragment{73};

    {
      CaptureBuffer buffer{memory, quota, 1024};

      check(buffer.append(std::span{fragment}.first(200)) == 200);
      buffer.append(fragment);
      check(buffer.truncated);
      check(buffer.append(fragment) == 0);
      buffer.reset();
      check(!buffer.truncated && buffer.size() == 0);
      check(buffer.append(fragment) == fragment.size());
    }

    check(quota.used() == 0);
  }

  void testCaptureFailuresAndMetadata() {
    SystemAllocator system;
    BudgetAllocator budget{system, 300};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    CaptureQuota quota{2048};
    ProxyCaptureLimits limits{.part_bytes = 512, .exchange_bytes = 1024, .total_bytes = 2048, .enabled = true};

    {
      CaptureHalf half{memory, quota, limits, CaptureStart{.host = "example.test"}};

      check(quota.used() == 0 && budget.liveBytes() == 0);
      half.appendHead("POST /request HTTP/1.1\r\nContent-Encoding: gzip\r\n\r\n");
      check(half.method() == "POST" && half.target() == "/request" && half.encoding() == "gzip");
      check(!half.append(CapturePart::response_head, "wrong side"));
      check(!half.append(CapturePart::request_body, "body"));
      check(half.body.truncated && half.truncation.total);
      check(half.head.size() != 0 && half.body.size() == 0);
      half.setMethod(std::string(33, 'm'));
      check(half.method() == "POST" && half.head.truncated);
      half.setEncoding(std::string(129, 'e'));
      check(half.encoding().size() == 128 && half.body.truncated);
    }

    check(budget.liveBytes() == 0 && quota.used() == 0);

    limits.part_bytes = 10;
    limits.exchange_bytes = 30;
    {
      CaptureHalf half{memory, quota, limits, CaptureStart{}};

      check(!half.append(CapturePart::request_head, "01234567890"));
      check(half.truncation.part && !half.truncation.exchange);
      check(!half.append(CapturePart::request_body, "abcdef"));
      check(half.truncation.exchange && half.capturedBytes() == 15);
      half.head.reset();
      check(!half.append(CapturePart::request_body, "12345"));
      check(half.body.size() == 10 && half.body.truncated);
    }
  }

  void testCaptureJoinOwnership() {
    SystemAllocator system;
    BudgetAllocator budget{system, 8 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    CaptureQuota quota{4096};
    ProxyCaptureLimits limits;
    using Joiner = CaptureJoiner;
    auto half = [&](std::uint64_t connection, CaptureSide side) {
      return makeOwned<CaptureHalf>(memory, memory, quota, limits, CaptureStart{.key = {connection, 1}, .side = side});
    };

    {
      Joiner joiner{memory, std::chrono::milliseconds{30}};

      check(joiner.push(10, half(1, CaptureSide::response)).state == Joiner::State::pending);
      auto duplicate = joiner.push(20, half(1, CaptureSide::response));

      check(duplicate.state == Joiner::State::partial && duplicate.exchange.response && !duplicate.exchange.request);
      auto complete = joiner.push(30, half(1, CaptureSide::request));

      check(complete.state == Joiner::State::complete && complete.exchange.request && complete.exchange.response);
      check(!joiner.expire(40));

      for (std::size_t index = 0; index < Joiner::capacity; ++index) {
        check(joiner.push(index, half(index + 1, CaptureSide::request)).state == Joiner::State::pending);
      }

      check(joiner.push(0, half(500, CaptureSide::response)).state == Joiner::State::full);
      check(!joiner.expire(29));
      auto expired = joiner.expire(30);

      check(expired && expired->request->key.connection == 1);
      check(joiner.push(std::numeric_limits<std::int64_t>::max(), half(500, CaptureSide::response)).state == Joiner::State::pending);
      check(joiner.push(31, half(2, CaptureSide::response)).state == Joiner::State::complete);
    }

    check(budget.liveBytes() == 0 && quota.used() == 0);
  }

  void testConcurrentCaptureQuota() {
    CaptureQuota quota{1024};
    std::array<std::jthread, 4> threads;

    for (auto& thread : threads) {
      thread = std::jthread{[&] {
        for (std::size_t iteration = 0; iteration < 10000; ++iteration) {
          const auto reserved = quota.reserveAtMost(300);

          check(quota.used() <= 1024);
          quota.release(reserved);
        }
      }};
    }

    for (auto& thread : threads) {
      thread.join();
    }

    check(quota.used() == 0);
  }

  const telar::testing::Case case_capture_growth_and_erasure{"exchange_capture.capture_growth_and_erasure", testCaptureGrowthAndErasure};
  const telar::testing::Case case_capture_failures_and_metadata{"exchange_capture.capture_failures_and_metadata", testCaptureFailuresAndMetadata};
  const telar::testing::Case case_capture_join_ownership{"exchange_capture.capture_join_ownership", testCaptureJoinOwnership};
  const telar::testing::Case case_concurrent_capture_quota{"exchange_capture.concurrent_capture_quota", testConcurrentCaptureQuota};

}
