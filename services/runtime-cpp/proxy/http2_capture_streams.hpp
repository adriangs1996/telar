#pragma once

#include "../exchange_capture/clock.hpp"
#include "../exchange_capture/producer.hpp"
#include "../http1/number.hpp"
#include "../http2/event.hpp"
#include "../http2/stream_tracker.hpp"
#include "counters.hpp"
#include "telar_base/memory/slot_indexes.hpp"
#include <utility>

namespace telar::runtime {

template <ConcurrentAllocator Memory, CaptureClock Clock = CaptureWallClock>
class Http2CaptureStreams {
public:
  explicit Http2CaptureStreams(CaptureProducer<Memory> *producer, ProxyCounters &counters, CaptureStart context, CaptureSide side) noexcept
      : producer_(producer), counters_(counters), context_(context) {
    context_.side = side;
  }

  Http2CaptureStreams(Http2CaptureStreams &&other) noexcept
      : producer_(other.producer_), counters_(other.counters_), context_(other.context_), slots_(std::move(other.slots_)), occupied_(std::exchange(other.occupied_, {})) {}

  Http2CaptureStreams(const Http2CaptureStreams &) = delete;
  Http2CaptureStreams &operator=(const Http2CaptureStreams &) = delete;
  Http2CaptureStreams &operator=(Http2CaptureStreams &&) = delete;

  ~Http2CaptureStreams() { finish(); }

  void head(const Http2Event &event) noexcept {
    auto *half = ensure(event.stream);
    if (half == nullptr) {
      return;
    }

    const auto part = half->headPart();
    half->append(part, event.name);
    half->append(part, ": ");
    half->append(part, event.value);
    half->append(part, "\r\n");

    if (context_.side == CaptureSide::request) {
      if (event.name == ":method") {
        half->setMethod(event.value);
      } else if (event.name == ":path") {
        half->setTarget(event.value);
      }
    } else if (event.name == ":status") {
      const auto status = parseHttpNumber<10>(event.value);
      half->status_code = status && *status <= std::numeric_limits<std::uint16_t>::max() ? static_cast<std::uint16_t>(*status) : 0;
      if (half->status_code >= 100 && half->status_code < 200) {
        half->head.reset();
      }
    }

    if (asciiEqualIgnoreCase(event.name, "content-encoding")) {
      half->setEncoding(event.value);
    }
  }

  void body(const Http2Event &event) noexcept {
    if (const auto index = find(event.stream)) {
      auto &half = *slots_[*index];
      half->append(half->bodyPart(), event.bytes);
    }
  }

  void finish(std::uint32_t stream, CaptureOutcome outcome) noexcept {
    if (const auto index = find(stream)) {
      publish(*index, outcome);
    }
  }

  void finish() noexcept {
    occupied_.forEach([this](std::size_t index) { publish(index, CaptureOutcome::reset); });
  }

  static constexpr std::size_t capacity = Http2StreamTracker::capacity;

private:
  CaptureHalf<Memory> *ensure(std::uint32_t stream) noexcept {
    if (producer_ == nullptr) {
      return nullptr;
    }
    if (const auto existing = find(stream)) {
      return slots_[*existing]->get();
    }

    const auto index = occupied_.firstUnused();
    if (!index) {
      counters_.record(ProxyCounter::h2_capture_stream_skipped);
      return nullptr;
    }

    context_.key.stream = stream;
    context_.started_at_ms = Clock::now();
    auto half = producer_->start(context_);
    if (!half) {
      return nullptr;
    }

    slots_[*index].emplace(std::move(half));
    occupied_.insert(*index);
    return slots_[*index]->get();
  }

  std::optional<std::size_t> find(std::uint32_t stream) const noexcept {
    std::optional<std::size_t> found;
    occupied_.forEach([&](std::size_t index) {
      if ((*slots_[index])->key.stream == stream) {
        found = index;
      }
    });
    return found;
  }

  void publish(std::size_t index, CaptureOutcome outcome) noexcept {
    auto half = std::move(*slots_[index]);
    slots_[index].reset();
    occupied_.erase(index);
    half->finish(outcome, Clock::now());
    producer_->publish(std::move(half));
  }

  CaptureProducer<Memory> *producer_;
  ProxyCounters &counters_;
  CaptureStart context_;
  std::array<std::optional<typename CaptureProducer<Memory>::Half>, capacity> slots_;
  SlotIndexes<capacity> occupied_;
};

}
