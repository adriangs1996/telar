#pragma once

#include "../exchange_capture/clock.hpp"
#include "../exchange_capture/producer.hpp"
#include "http1_capture_policy.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, CaptureClock Clock = CaptureWallClock>
class Http1Capture {
public:
  explicit Http1Capture(Memory &memory, CaptureProducer<Memory> *producer, CaptureStart context) noexcept
      : producer_(producer), context_(context), exchange_(memory) {}

  void begin() noexcept {
    exchange_.request.reset();
    exchange_.response.reset();
    if (producer_ == nullptr) {
      return;
    }

    context_.started_at_ms = Clock::now();
    context_.side = CaptureSide::request;
    exchange_.request = producer_->start(context_);
    context_.side = CaptureSide::response;
    exchange_.response = producer_->start(context_);
  }

  void head(CaptureSide side, std::string_view bytes) noexcept {
    if (auto &half = select(side)) {
      half->appendHead(bytes);
    }
  }

  void payload(CaptureSide side, std::span<const std::uint8_t> bytes) noexcept {
    if (auto &half = select(side)) {
      half->append(half->bodyPart(), bytes);
    }
  }

  void finishRequest() noexcept {
    finish(CaptureSide::request, CaptureOutcome::finished);
  }

  void finishResponse(std::uint16_t status, bool complete = true) noexcept {
    if (exchange_.response) {
      exchange_.response->status_code = status;
    }
    finish(CaptureSide::response, !complete || status >= 400 ? CaptureOutcome::failed : CaptureOutcome::finished);
  }

  void discardInformational() noexcept {
    if (exchange_.response) {
      exchange_.response->head.reset();
    }
  }

  void fail() noexcept {
    finish(CaptureSide::request, CaptureOutcome::failed);
    finish(CaptureSide::response, CaptureOutcome::failed);
  }

private:
  using Half = typename CaptureProducer<Memory>::Half;

  Half &select(CaptureSide side) noexcept {
    return side == CaptureSide::request ? exchange_.request : exchange_.response;
  }

  void finish(CaptureSide side, CaptureOutcome outcome) noexcept {
    auto &half = select(side);
    if (half) {
      half->finish(outcome, Clock::now());
      producer_->publish(std::move(half));
    }
  }

  CaptureProducer<Memory> *producer_;
  CaptureStart context_;
  CapturedExchange<Memory> exchange_;
};

template <ConcurrentAllocator Memory>
Http1Capture(Memory &memory, CaptureProducer<Memory> *producer, CaptureStart context) -> Http1Capture<Memory>;

}
