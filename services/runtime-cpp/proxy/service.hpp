#pragma once

#include "telar_platform/thread_name.hpp"

#include "connection.hpp"
#include "listener.hpp"
#include "refusal.hpp"
#include "socket_watch.hpp"
#include "telar_base/memory/drop_channel.hpp"
#include "telar_base/memory/slot_indexes.hpp"
#include <thread>

namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, HostnameResolver Resolver>
class ProxyService {
public:
  explicit ProxyService(Memory &memory, const ProxyOptions<Memory> &options, const ProxySecret &secret, const TlsInterception<Memory> &interception, ProxyListener listener, traffic::FlowControl *flows = nullptr)
      : memory_(memory), options_(options), secret_(secret), interception_(interception), listener_(std::move(listener)), observations_(memory, options.capture, flows), poller_(memory), resolutions_(resolution_signal_), flows_(flows) {
    poller_.watch(listener_.descriptor(), listener_token);
    poller_.watch(stop_signal_.descriptor(), stop_token);
    poller_.watch(resolution_signal_.descriptor(), resolution_token);
    poller_.watch(adoption_signal_.descriptor(), adoption_token);
    if (flows_) { poller_.watch(flows_->descriptor(), flow_token); }
    worker_ = std::thread{[this] { run(); }};
  }

  ~ProxyService() {
    stopping_.store(true, std::memory_order_release);
    stop_signal_.notify();
    worker_.join();
  }

  ProxyService(const ProxyService &) = delete;
  ProxyService &operator=(const ProxyService &) = delete;

  std::uint16_t port() const noexcept {
    return listener_.port();
  }

  const ProxyCounters &counters() const noexcept {
    return observations_.counters;
  }

  CaptureProducer<Memory> &captures() noexcept {
    return observations_.captures;
  }

  const CaptureProducer<Memory> &captures() const noexcept {
    return observations_.captures;
  }

  std::uint32_t active() const noexcept {
    return active_.load(std::memory_order_relaxed);
  }

  std::uint64_t limitDrops() const noexcept {
    return limit_drops_.load(std::memory_order_relaxed);
  }

  bool failed() const noexcept {
    return failed_.load(std::memory_order_acquire);
  }

  bool adopt(redirect::Connection connection) noexcept {
    if (stopping_.load(std::memory_order_acquire) || failed()) {
      return false;
    }
    const bool accepted = adoptions_.publish(std::move(connection));
    if (!accepted) {
      limit_drops_.fetch_add(1, std::memory_order_relaxed);
    }
    adoption_signal_.notify();
    return accepted;
  }

private:
  using Policy = ProxyConnectionPolicy;
  using Time = Policy::Time;
  using Connection = ProxyConnection<Memory, Resolver>;

  struct Slot {
    explicit Slot(Owned<Connection, Memory> connection, std::uint64_t generation) noexcept
        : connection(std::move(connection)), child_generation(generation) {}

    Owned<Connection, Memory> connection;
    SocketWatch child;
    SocketWatch origin;
    std::uint64_t child_generation;
    std::uint64_t origin_generation = 0;
    std::size_t origin_attempt = 0;
  };

  void run() noexcept {
    setThreadName("telar.proxy");
    try {
      auto reap_at = Policy::Clock::now() + reap_interval;
      while (!stopping_.load(std::memory_order_acquire)) {
        const auto now = Policy::Clock::now();
        auto wake_at = reap_at;
        advanceRefusal(now);
        if (refusal_) {
          wake_at = std::min(wake_at, refusal_->deadline());
        } else if (accept_after_ != Time{}) {
          if (now >= accept_after_) {
            accept_after_ = {};
            poller_.readInterest(listener_.descriptor(), listener_token, true);
          } else {
            wake_at = std::min(wake_at, accept_after_);
          }
        }

        occupied_.forEach([&](std::size_t index) {
          auto &slot = slots_[index];
          if (now >= reap_at) {
            slot->connection->expire(now);
            advance(index, {}, now);
          } else if (slot->connection->buffered() || (slot->connection->deadline() && now >= *slot->connection->deadline())) {
            advance(index, TunnelReadiness::available(), now);
          }
          if (slot) {
            if (const auto deadline = slot->connection->deadline()) {
              wake_at = std::min(wake_at, *deadline);
            }
            if (slot->connection->buffered()) {
              wake_at = now;
            }
          }
        });
        if (now >= reap_at) {
          reap_at = now + reap_interval;
        }

        const auto events = poller_.wait(wake_at - Policy::Clock::now());
        for (const auto &event : events) {
          if (stopping_.load(std::memory_order_acquire)) {
            break;
          }
          dispatch(event, Policy::Clock::now());
        }
      }
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar proxy service: %s\n", error.what());
      failed_.store(true, std::memory_order_release);
    } catch (...) {
      failed_.store(true, std::memory_order_release);
    }

    refusal_watch_.remove(poller_);
    refusal_.reset();
    occupied_.forEach([this](std::size_t index) { release(index); });
    adoptions_.close();
    poller_.remove(listener_.descriptor());
    listener_.close();
  }

  void dispatch(const Event &event, Time now) {
    if (event.token == listener_token) {
      if (!refusal_ && accept_after_ == Time{}) {
        accept(now);
      }
    } else if (event.token == stop_token) {
      stop_signal_.drain();
    } else if (event.token == resolution_token) {
      resolution_signal_.drain();
      occupied_.forEach([&](std::size_t index) {
        if (slots_[index]->connection->policy().phase() == Policy::Phase::establishing) {
          advance(index, {}, now);
        }
      });
    } else if (event.token == flow_token) {
      flows_->drain();
      occupied_.forEach([&](std::size_t index) { advance(index, TunnelReadiness::available(), now); });
    } else if (event.token == adoption_token) {
      adoption_signal_.drain();
      while (auto connection = adoptions_.tryReceive()) {
        const auto index = admit(now, true);
        if (!index) {
          continue;
        }
        try {
          keep(makeOwned<Connection>(memory_, memory_, std::move(*connection), options_, secret_, observations_.counters), *index, now);
        } catch (...) {
          release(*index);
        }
      }
    } else if (event.token == refusal_token) {
      if (refusal_watch_.matches(event)) {
        advanceRefusal(now);
      }
    } else {
      const auto index = (event.token >> side_bits) & slot_mask;
      auto &slot = slots_[index];
      if (slot && (slot->child.matches(event) || slot->origin.matches(event))) {
        TunnelReadiness readiness;
        auto &side = slot->origin.matches(event) ? readiness.origin : readiness.child;
        side = {.readable = event.kind == EventKind::readable, .writable = event.kind == EventKind::writable};
        advance(index, readiness, now);
      }
    }
  }

  void accept(Time now) {
    TELAR_TRACE("proxy.acceptConnections");
    for (std::size_t accepted = 0; accepted < maximum_accept_batch; ++accepted) {
      FileDescriptor child;
      try {
        child = listener_.accept();
      } catch (const SystemError &error) {
        if (error.code() == EMFILE || error.code() == ENFILE || error.code() == ENOBUFS || error.code() == ENOMEM) {
          accept_after_ = now + descriptor_backoff;
          poller_.readInterest(listener_.descriptor(), listener_token, false);
        }
        return;
      }
      if (!child) {
        return;
      }

      const auto index = admit(now);
      if (!index) {
        refusal_.emplace(std::move(child), now);
        poller_.readInterest(listener_.descriptor(), listener_token, false);
        advanceRefusal(now);
        return;
      }
      try {
        auto connection = makeOwned<Connection>(memory_, memory_, std::move(child), options_, secret_, observations_.counters);
        keep(std::move(connection), *index, now);
      } catch (...) {
        release(*index);
      }
    }
  }

  void keep(Owned<Connection, Memory> connection, std::size_t index, Time now) {
    slots_[index].emplace(std::move(connection), nextGeneration());
    occupied_.insert(index);
    active_.fetch_add(1, std::memory_order_relaxed);
    advance(index, {}, now);
  }

  std::optional<std::size_t> admit(Time now, bool authenticated = false) noexcept {
    std::size_t unauthenticated = 0;
    occupied_.forEach([&](std::size_t index) { unauthenticated += slots_[index]->connection->policy().phase() == Policy::Phase::connect_head; });
    if (!authenticated && unauthenticated >= Policy::maximum_unauthenticated) {
      if (const auto evicted = oldest(Policy::Closure::evict_head, now)) {
        release(*evicted);
        observations_.counters.record(ProxyCounter::unauthenticated_eviction);
      } else {
        observations_.counters.record(ProxyCounter::unauthenticated_refusal);
        return std::nullopt;
      }
    }

    if (const auto available = occupied_.firstUnused()) {
      return available;
    }
    for (const auto reason : {Policy::Closure::evict_head, Policy::Closure::evict_idle, Policy::Closure::evict_silent}) {
      if (const auto evicted = oldest(reason, now)) {
        release(*evicted);
        observations_.counters.record(ProxyCounter::eviction);
        return evicted;
      }
    }
    limit_drops_.fetch_add(1, std::memory_order_relaxed);
    return std::nullopt;
  }

  std::optional<std::size_t> oldest(Policy::Closure reason, Time now) const noexcept {
    std::optional<std::size_t> found;
    auto since = Time::max();
    occupied_.forEach([&](std::size_t index) {
      const auto &policy = slots_[index]->connection->policy();
      const auto started = reason == Policy::Closure::evict_head ? policy.since() : policy.active();
      if (policy.evictable(reason, now) && started < since) {
        since = started;
        found = index;
      }
    });
    return found;
  }

  void advance(std::size_t index, TunnelReadiness readiness, Time now) noexcept {
    auto &slot = *slots_[index];
    slot.connection->advance(interception_, observations_, readiness, now);
    if (slot.connection->closed()) {
      release(index);
      return;
    }

    try {
      if (slot.origin_attempt != slot.connection->originAttempt()) {
        slot.origin_attempt = slot.connection->originAttempt();
        slot.origin_generation = nextGeneration();
      }
      slot.child.update(poller_, slot.connection->descriptor(TlsSide::child), token(index, slot.child_generation, TlsSide::child), slot.connection->interest(TlsSide::child));
      slot.origin.update(poller_, slot.connection->descriptor(TlsSide::origin), token(index, slot.origin_generation, TlsSide::origin), slot.connection->interest(TlsSide::origin));
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar proxy watch: %s\n", error.what());
      release(index);
    } catch (...) {
      release(index);
    }
  }

  void advanceRefusal(Time now) {
    if (!refusal_) {
      return;
    }
    if (refusal_->advance(now)) {
      refusal_watch_.remove(poller_);
      refusal_.reset();
      poller_.readInterest(listener_.descriptor(), listener_token, true);
    } else {
      refusal_watch_.update(poller_, refusal_->descriptor(), refusal_token, refusal_->interest());
    }
  }

  void release(std::size_t index) noexcept {
    auto &slot = slots_[index];
    if (slot) {
      slot->child.remove(poller_);
      slot->origin.remove(poller_);
      slot.reset();
      occupied_.erase(index);
      active_.fetch_sub(1, std::memory_order_relaxed);
    }
  }

  static std::uint64_t token(std::size_t index, std::uint64_t generation, TlsSide side) noexcept {
    return (generation << generation_shift) | (index << side_bits) | (side == TlsSide::origin ? 1 : 0);
  }

  std::uint64_t nextGeneration() {
    if (generation_ == (UINT64_MAX >> generation_shift)) {
      throw SystemError{"Proxy event generations exhausted", EOVERFLOW};
    }
    return ++generation_;
  }

  static constexpr std::uint64_t listener_token = 1;
  static constexpr std::uint64_t stop_token = 2;
  static constexpr std::uint64_t resolution_token = 3;
  static constexpr std::uint64_t refusal_token = 4;
  static constexpr std::uint64_t adoption_token = 5;
  static constexpr std::uint64_t flow_token = 6;
  static constexpr unsigned side_bits = 1;
  static constexpr unsigned slot_bits = 8;
  static constexpr unsigned generation_shift = slot_bits + side_bits;
  static constexpr std::size_t slot_mask = Policy::capacity - 1;
  static constexpr std::size_t maximum_accept_batch = 32;
  static constexpr auto reap_interval = std::chrono::seconds{1};
  static constexpr auto descriptor_backoff = std::chrono::milliseconds{100};
  static_assert(Policy::capacity == 1 << slot_bits);

  Memory &memory_;
  const ProxyOptions<Memory> &options_;
  const ProxySecret &secret_;
  const TlsInterception<Memory> &interception_;
  ProxyListener listener_;
  ProxyObservations<Memory> observations_;
  Poller poller_;
  CompletionSignal stop_signal_;
  CompletionSignal resolution_signal_;
  CompletionSignal adoption_signal_;
  DropChannel<redirect::Connection, 32> adoptions_;
  typename NameResolutions<Resolver>::Notifications resolutions_;
  traffic::FlowControl *flows_;
  std::array<std::optional<Slot>, Policy::capacity> slots_;
  SlotIndexes<Policy::capacity> occupied_;
  std::optional<ProxyRefusal> refusal_;
  SocketWatch refusal_watch_;
  Time accept_after_{};
  std::uint64_t generation_ = 0;
  std::atomic<std::uint32_t> active_ = 0;
  std::atomic<std::uint64_t> limit_drops_ = 0;
  std::atomic<bool> stopping_ = false;
  std::atomic<bool> failed_ = false;
  std::thread worker_;
};

}
