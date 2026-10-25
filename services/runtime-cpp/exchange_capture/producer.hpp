#pragma once

#include "../memory/drop_channel.hpp"
#include "content_decoder.hpp"
#include "exchange.hpp"
#include "metrics.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class CaptureProducer {
public:
  using Half = typename CapturedExchange<Memory>::Half;

  explicit CaptureProducer(Memory &memory, ProxyCaptureLimits limits)
      : memory_(memory), limits_(limits), quota_(limits.total_bytes) {
    if (!limits.valid()) {
      throw std::invalid_argument{"Invalid proxy capture limits"};
    }
  }

  Half start(CaptureStart context) noexcept {
    Half absent{nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory_}};
    if (!limits_.enabled) {
      return absent;
    }
    if (context.host.size() <= CaptureHalf<Memory>::maximum_host_bytes) {
      try {
        auto half = makeOwned<CaptureHalf<Memory>>(memory_, memory_, quota_, limits_, context);
        if (context.side == CaptureSide::request) {
          started_.fetch_add(1, std::memory_order_relaxed);
        }
        return half;
      } catch (const std::bad_alloc &) {
      }
    }
    skipped_.fetch_add(1, std::memory_order_relaxed);
    return absent;
  }

  bool publish(Half half) noexcept {
    if (half->head.truncated || half->body.truncated) {
      truncated_.fetch_add(1, std::memory_order_relaxed);
    }
    countTruncation(half->truncation);
    return channel_.publish(std::move(half));
  }

  std::optional<Half> receive() { return channel_.receive(); }
  std::optional<Half> tryReceive() noexcept { return channel_.tryReceive(); }
  void close() noexcept { channel_.close(); }
  std::size_t reservedBytes() const noexcept { return quota_.used(); }

  void decodeBody(CaptureHalf<Memory> &half) noexcept {
    if (half.encoding().empty() || asciiEqualIgnoreCase(half.encoding(), "identity")) {
      half.body_decoded = true;
      return;
    }

    const auto share_room = half.bodyLimit();
    const auto available = std::min(limits_.part_bytes, share_room);
    if (available == 0) {
      return;
    }

    try {
      CaptureContentDecoder decoder{memory_};
      auto result = decoder.decode(half.body.bytes(), half.encoding(), available);
      if (result.failed) {
        decode_failed_.fetch_add(1, std::memory_order_relaxed);
        return;
      }

      const bool was_truncated = half.body.truncated;
      const auto previous = half.truncation;
      half.body.reset();
      half.append(half.bodyPart(), result.bytes());
      if (result.truncated) {
        if (limits_.part_bytes <= share_room) {
          half.truncation.part = true;
        } else {
          half.truncation.exchange = true;
        }
      }
      half.body.truncated = half.body.truncated || result.truncated || was_truncated;
      half.body_decoded = result.decoded;
      if (!was_truncated && half.body.truncated) {
        truncated_.fetch_add(1, std::memory_order_relaxed);
      }
      countTruncation({half.truncation.part && !previous.part, half.truncation.exchange && !previous.exchange, half.truncation.total && !previous.total});
    } catch (...) {
      decode_failed_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  CaptureMetrics metrics() const noexcept {
    const auto queue = channel_.metrics();
    return {
        .started = started_.load(std::memory_order_relaxed),
        .truncated = truncated_.load(std::memory_order_relaxed),
        .truncated_part = truncated_part_.load(std::memory_order_relaxed),
        .truncated_exchange = truncated_exchange_.load(std::memory_order_relaxed),
        .truncated_total = truncated_total_.load(std::memory_order_relaxed),
        .skipped = skipped_.load(std::memory_order_relaxed),
        .decode_failed = decode_failed_.load(std::memory_order_relaxed),
        .dropped_queue = queue.dropped,
        .queued = queue.queued,
        .queue_high_water = queue.high_water,
    };
  }

  static constexpr std::size_t queue_capacity = 256;

private:
  void countTruncation(CaptureTruncation truncation) noexcept {
    if (truncation.part) {
      truncated_part_.fetch_add(1, std::memory_order_relaxed);
    }
    if (truncation.exchange) {
      truncated_exchange_.fetch_add(1, std::memory_order_relaxed);
    }
    if (truncation.total) {
      truncated_total_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  Memory &memory_;
  const ProxyCaptureLimits limits_;
  CaptureQuota quota_;
  DropChannel<Half, queue_capacity> channel_;
  std::atomic<std::uint64_t> started_{0};
  std::atomic<std::uint64_t> truncated_{0};
  std::atomic<std::uint64_t> truncated_part_{0};
  std::atomic<std::uint64_t> truncated_exchange_{0};
  std::atomic<std::uint64_t> truncated_total_{0};
  std::atomic<std::uint64_t> skipped_{0};
  std::atomic<std::uint64_t> decode_failed_{0};
};

}
