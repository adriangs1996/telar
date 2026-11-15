module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.proxy.http2_capture_streams;


namespace telar::runtime {

  ConnectHead::ConnectHead() noexcept {}

  auto ConnectHead::receive(int socket) noexcept -> Read {
    SocketStream stream{socket};

    return reader_.receive(stream, storage_.bytes(), "\r\n\r\n");
  }

  std::string_view ConnectHead::text() noexcept {
    return {reinterpret_cast<const char*>(storage_.bytes().data()), reader_.length()};
  }

  void ConnectHead::erase() noexcept {
    eraseSensitive(storage_.bytes().data(), capacity);
    reader_.reset();
  }

  ProxyConnectionPolicy::ProxyConnectionPolicy(Time now) noexcept
      : since_(now),
        active_(now) {}

  void ProxyConnectionPolicy::enter(Phase phase, Time now) noexcept {
    if (phase_ != phase) {
      phase_ = phase;
      since_ = now;
    }
  }

  void ProxyConnectionPolicy::touch(Time now) noexcept {
    active_ = now;
  }

  void ProxyConnectionPolicy::exchanges(std::uint32_t count) noexcept {
    exchanges_ = count;
  }

  auto ProxyConnectionPolicy::phase() const noexcept -> Phase {
    return phase_;
  }

  auto ProxyConnectionPolicy::since() const noexcept -> Time {
    return since_;
  }

  auto ProxyConnectionPolicy::active() const noexcept -> Time {
    return active_;
  }

  auto ProxyConnectionPolicy::expired(Time now) const noexcept -> Closure {
    switch (phase_) {
    case Phase::connect_head:
      return now - since_ >= head_timeout ? Closure::head_timeout : Closure::none;
    case Phase::establishing:
      return now - since_ >= establishment_timeout ? Closure::establishment_timeout : Closure::none;
    case Phase::half_closed:
      return now - active_ >= half_closed_timeout ? Closure::half_closed_timeout : Closure::none;
    default:
      return Closure::none;
    }
  }

  bool ProxyConnectionPolicy::evictable(Closure reason, Time now) const noexcept {
    switch (reason) {
    case Closure::evict_head:
      return phase_ == Phase::connect_head && now - since_ >= evictable_head_age;
    case Closure::evict_idle:
      return phase_ == Phase::idle && exchanges_ == 0 && now - active_ >= evictable_idle_age;
    case Closure::evict_silent:
      return phase_ == Phase::open && exchanges_ == 0 && now - active_ >= evictable_silent_age;
    default:
      return false;
    }
  }

  void ProxyCounters::record(ProxyCounter counter, std::uint64_t count) noexcept {
    counters_[static_cast<std::size_t>(counter)].fetch_add(count, std::memory_order_relaxed);
  }

  std::uint64_t ProxyCounters::read(ProxyCounter counter) const noexcept {
    return counters_[static_cast<std::size_t>(counter)].load(std::memory_order_relaxed);
  }

  auto ProxyCounters::snapshot() const noexcept -> std::array<std::uint64_t, capacity> {
    std::array<std::uint64_t, capacity> result;

    for (std::size_t index = 0; index != capacity; ++index) {
      result[index] = counters_[index].load(std::memory_order_relaxed);
    }

    return result;
  }

  std::uint64_t ProxyMetrics::read(ProxyCounter counter) const noexcept {
    return counters[static_cast<std::size_t>(counter)];
  }
}
