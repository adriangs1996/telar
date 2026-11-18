module telar.runtime.exchange_capture.pipeline;

import telar.platform.thread;
import telar.base.ds;

namespace telar::runtime {

  std::int64_t CaptureWallClock::now() noexcept {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  }

  CaptureJoiner::CaptureJoiner(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::chrono::milliseconds timeout) noexcept
      : memory_(memory),
        timeout_ms_(timeout.count()) {}

  auto CaptureJoiner::push(std::int64_t now_ms, tbc::view<Half, tbc::lt::a> half) noexcept -> tbc::view<Result, tbc::lt::a> {
    Result result{State::pending, CapturedExchange{memory_}};
    const auto existing = find(half->key);
    if (existing) {
      auto& entry = slots_.atMut(*existing).getMut();
      if (entry.half->side == half->side) {
        result.state = State::partial;
      } else {
        result.state = State::complete;
        result.exchange.include(std::move(entry.half));
        slots_.atMut(*existing).reset();
        occupied_.erase(*existing);
      }

      result.exchange.include(std::move(half));
      return result;
    }

    const auto available = occupied_.firstUnused();
    if (!available) {
      result.state = State::full;
      result.exchange.include(std::move(half));
      return result;
    }

    const auto maximum_time = std::numeric_limits<std::int64_t>::max();
    const auto deadline = now_ms > maximum_time - timeout_ms_ ? maximum_time : now_ms + timeout_ms_;

    slots_.atMut(*available).emplace(std::move(half), deadline);
    occupied_.insert(*available);
    return result;
  }

  tbc::view<ds::Option<CapturedExchange>, tbc::lt::a> CaptureJoiner::expire(std::int64_t now_ms) noexcept {
    ds::Option<std::size_t> expired;

    occupied_.forEach([&](std::size_t index) {
      if (!expired && slots_[index]->expires_at_ms <= now_ms) {
        expired = index;
      }
    });

    if (!expired) {
      return ds::none;
    }

    CapturedExchange result{memory_};

    result.include(std::move(slots_.atMut(*expired).getMut().half));
    slots_.atMut(*expired).reset();
    occupied_.erase(*expired);
    return result;
  }

  ds::Option<std::size_t> CaptureJoiner::find(CaptureKey key) const noexcept {
    ds::Option<std::size_t> found;

    occupied_.forEach([&](std::size_t index) {
      if (slots_[index]->half->key == key) {
        found = index;
      }
    });

    return found;
  }

  CaptureReceiver::CaptureReceiver(CaptureProducer& producer) noexcept
      : producer_(producer) {}

  auto CaptureReceiver::observe(const Request& request) noexcept -> Result {
    if (!named_) {
      setThreadName("telar.capture");
      named_ = true;
    }

    auto half = producer_.receive();
    if (half && request.decode) {
      producer_.decodeBody(*half.getMut());
    }

    return half;
  }

  void CaptureReceiver::stop() noexcept {
    producer_.close();
  }

}
