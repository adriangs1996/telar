#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstring>
#include <cstddef>
#include <cstdint>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>
#include <cassert>

import std;
import telar.base.memory;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.tests.erasure_checking_allocator;
import telar.runtime.exchange_capture.producer;

using namespace telar;
using namespace telar::runtime;

static std::vector<std::uint8_t> decodeHexadecimal(std::string_view text) {
  std::vector<std::uint8_t> result;
  for (std::size_t offset = 0; offset < text.size(); offset += 2) {
    unsigned byte = 0;
    const auto parsed = std::from_chars(text.data() + offset, text.data() + offset + 2, byte, 16);
    check(parsed.ec == std::errc{} && parsed.ptr == text.data() + offset + 2);
    result.push_back(static_cast<std::uint8_t>(byte));
  }
  return result;
}

void testCaptureDecoding() {
  struct Fixture {
    std::string_view coding;
    std::string_view hexadecimal;
  };
  const std::array fixtures{
      Fixture{"gzip", "1f8b08000000000002ff4b4e2c28292d4a5548ca4fa904009b1d16120c000000"},
      Fixture{"deflate", "789c4b4e2c28292d4a5548ca4fa904001f2904c3"},
      Fixture{"br", "8b05806361707475726520626f647903"},
      Fixture{"zstd", "28b52ffd200c6100006361707475726520626f6479"},
  };
  constexpr std::string_view plaintext = "capture body";
  ErasureCheckingAllocator system;

  for (const auto &fixture : fixtures) {
    const auto input = decodeHexadecimal(fixture.hexadecimal);
    for (const std::size_t limit : {1, 11, 12, 13, 1024}) {
      BudgetAllocator memory{system, 2 * 1024 * 1024};
      {
        CaptureContentDecoder decoder{memory};
        const auto body = decoder.decode(input, fixture.coding, limit);
        check(body.decoded && !body.failed && body.truncated == (limit < plaintext.size()));
        check(std::string_view{reinterpret_cast<const char *>(body.bytes().data()), body.size} == plaintext.substr(0, limit));
      }
      check(memory.liveBytes() == 0);
    }

    {
      const std::size_t budget = fixture.coding == "zstd" ? 128 * 1024 : fixture.coding == "br" ? 2 * 1024
                                                                                                : 32 * 1024;
      BudgetAllocator memory{system, budget};
      {
        CaptureContentDecoder decoder{memory};
        const auto body = decoder.decode(input, fixture.coding, 1024);
        check(body.decoded && !body.failed && !body.truncated);
        check(std::string_view{reinterpret_cast<const char *>(body.bytes().data()), body.size} == plaintext);
      }
      check(memory.liveBytes() == 0);
    }

    for (const std::size_t budget : {0, 12, 1024, 65536, 131072}) {
      BudgetAllocator memory{system, budget};
      {
        CaptureContentDecoder decoder{memory};
        try {
          const auto body = decoder.decode(input, fixture.coding, 1024);
          check(body.decoded || body.failed);
        } catch (const std::bad_alloc &) {
        }
      }
      check(memory.liveBytes() == 0);
    }
  }

  BudgetAllocator memory{system, 1024};
  {
    auto first = SensitiveAllocation{memory, 127};
    auto second = SensitiveAllocation{memory, 63};
    std::fill(first.bytes().begin(), first.bytes().end(), 72);
    second = std::move(first);
    check(first.bytes().empty() && second.bytes().size() == 127 && memory.liveBytes() == 127);
    auto moved = std::move(second);
    check(second.bytes().empty() && moved.bytes().front() == 72);
  }
  check(memory.liveBytes() == 0);
}

static void testCapturePublication() {
  SystemAllocator system;
  BudgetAllocator budget{system, 8 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  ProxyCaptureLimits limits{.part_bytes = 64, .exchange_bytes = 128, .total_bytes = 32768, .enabled = true};
  CaptureProducer producer{memory, limits};
  for (std::size_t index = 0; index < producer.queue_capacity; ++index) {
    auto half = producer.start({.key = {index, 0}, .host = "host"});
    check(half && half->append(CapturePart::request_body, "x"));
    check(producer.publish(std::move(half)));
  }
  check(!producer.publish(producer.start({})));
  const auto metrics = producer.metrics();
  check(metrics.queued == producer.queue_capacity && metrics.queue_high_water == producer.queue_capacity);
  check(metrics.started == producer.queue_capacity + 1 && metrics.dropped_queue == 1);
  check(producer.reservedBytes() == producer.queue_capacity * 64);

  auto first = producer.tryReceive();
  check(first && (*first)->key.connection == 0);
  first.reset();
  producer.close();
  check(producer.reservedBytes() == 0 && producer.metrics().queued == 0 && budget.liveBytes() == 0);
  check(!producer.receive());
  check(!producer.publish(producer.start({})) && producer.metrics().dropped_queue == 2);
  check(!producer.start({.host = std::string(256, 'h')}) && producer.metrics().skipped == 1);
}

static void testDecodedCaptureCounters() {
  SystemAllocator memory;
  ProxyCaptureLimits limits{.part_bytes = 32, .exchange_bytes = 64, .total_bytes = 4096, .enabled = true};
  CaptureProducer producer{memory, limits};
  auto half = producer.start({});
  half->setEncoding("gzip");
  const auto compressed = decodeHexadecimal("1f8b0800000000000213aba8a03d00008f5d0e5e64000000");
  check(half->append(CapturePart::request_body, compressed));
  check(producer.publish(std::move(half)) && producer.metrics().truncated == 0);
  auto received = producer.receive();
  producer.decodeBody(**received);
  check((*received)->body_decoded && (*received)->body.truncated && (*received)->body.size() == 32);
  check(producer.metrics().truncated == 1 && producer.metrics().truncated_part == 1);

  auto malformed = producer.start({});
  malformed->setEncoding("br");
  malformed->append(CapturePart::request_body, "broken");
  producer.decodeBody(*malformed);
  check(producer.metrics().decode_failed == 1 && malformed->body.size() == 6 && !malformed->body_decoded);

  BudgetAllocator failing{memory, 0};
  SynchronizedAllocator synchronized{failing};
  CaptureProducer exhausted{synchronized, limits};
  check(!exhausted.start({}) && exhausted.metrics().skipped == 1 && exhausted.metrics().started == 0);
}

static void testConcurrentCaptureDelivery() {
  DropChannel<std::uint64_t, 8> channel;
  std::atomic<std::uint64_t> published{0};
  std::uint64_t received = 0;
  std::jthread consumer{[&] {
    while (const auto value = channel.receive()) {
      received += *value;
    }
  }};
  std::array<std::jthread, 4> producers;
  for (auto &thread : producers) {
    thread = std::jthread{[&] {
      for (std::uint64_t iteration = 1; iteration <= 1000; ++iteration) {
        if (channel.publish(iteration)) {
          published.fetch_add(iteration, std::memory_order_relaxed);
        }
      }
    }};
  }
  for (auto &thread : producers) {
    thread.join();
  }
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while (channel.metrics().queued != 0 && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::yield();
  }
  check(channel.metrics().queued == 0);
  channel.close();
  consumer.join();
  check(received == published.load(std::memory_order_relaxed));
}

void testCaptureProducer() {
  testCapturePublication();
  testDecodedCaptureCounters();
  testConcurrentCaptureDelivery();
}
