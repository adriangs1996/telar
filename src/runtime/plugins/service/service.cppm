module;
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <stdlib.h>

#include <cstddef>
#include <cstdint>

#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <cstring>
#include <cassert>
#include <poll.h>
#include <sys/uio.h>
#include <unistd.h>
#include <sys/types.h>
#include <climits>
#include <csignal>
#include <cstdio>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include "tbc/view.hpp"

export module telar.runtime.plugins.service;

import std;

export import telar.runtime.plugins.protocol;


export import telar.plugins;
export import telar.runtime.plugins.worker;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: plugins/event_source.cppm
export {
namespace telar::runtime::plugins {

struct TapMetrics {
  std::uint64_t dropped_queue = 0;
  std::uint64_t dropped_bytes = 0;
  std::uint64_t timeouts = 0;
  std::uint64_t disabled = 0;
};

template <typename Source>
concept EventSource = requires(Source &source, void (*consumer)(const EffectBatch &)) {
  { source.descriptor() } noexcept -> std::same_as<int>;
  { source.collect(consumer) } -> std::same_as<void>;
  { source.metrics() } noexcept -> std::same_as<TapMetrics>;
};

struct IgnoreEvents {
  inline int descriptor() const noexcept { return -1; }
  inline TapMetrics metrics() const noexcept { return {}; }

  template <typename Consumer>
  inline void collect(Consumer &&) const noexcept {}
};

}
}

// Interface: plugins/service.cppm
export {
namespace telar::runtime::plugins {

// Proxy threads submit exchanges and the runtime collects results while the trust monitor revokes
// workers: the workers are fixed once built, and what changes after is atomic or a synchronized
// channel, so every borrow the service lends stays valid whatever is done through it.
template <ConcurrentAllocator Memory>
class TBC_SHARED Service {
public:
  inline explicit Service(Memory &memory, std::span<const ServiceSpec> specifications, const char *executable, std::string_view trace_prefix = {}, traffic::PackagePort *traffic = nullptr)
      : memory_(memory), workers_(AllocatorRef<Owned<Worker<Memory>, Memory>, Memory>{memory}) {
    if (specifications.empty()) {
      return;
    }
    if (specifications.size() > Limits::workers) {
      throw std::invalid_argument{"Too many tap workers"};
    }

    cancellation_.emplace();
    results_.activate();
    workers_.reserve(specifications.size());
    try {
      for (const auto &specification : specifications) {
        workers_.push_back(makeOwned<Worker<Memory>>(memory, memory, specification, results_, budget_, WorkerLaunch{.executable = executable, .cancellation = *cancellation_, .trace_prefix = trace_prefix, .traffic = traffic}));
      }
    } catch (...) {
      stop();
      throw;
    }
  }

  inline ~Service() { stop(); }
  Service(const Service &) = delete;
  Service &operator=(const Service &) = delete;

  inline void watchTrust(std::string_view path) {
    if (workers_.empty()) { return; }
    if (stopped_.load(std::memory_order_acquire) || trust_monitor_.joinable() || path.empty()) { throw std::invalid_argument{"Invalid plugin trust monitor"}; }
    trust_path_.assign(path);
    refreshTrust();
    trust_monitor_ = std::jthread{[this] {
      pollfd wake{cancellation_->descriptor(), POLLIN, 0};
      while (!cancellation_->requested()) {
        const auto ready = ::poll(&wake, 1, static_cast<int>(Limits::trust_check_interval.count()));
        if (ready < 0 && errno == EINTR) { continue; }
        if (ready != 0) { return; }
        refreshTrust();
      }
    }};
  }

  inline void stop() noexcept {
    if (stopped_.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    if (cancellation_) {
      cancellation_->request();
    }
    if (trust_monitor_.joinable()) { trust_monitor_.join(); }
    for (const auto &worker : workers_) {
      worker->stop();
    }
    results_.close();
  }

  inline bool listening() const noexcept { return std::ranges::any_of(workers_, [](const auto &worker) { return !worker->revoked() && worker->specification().allows(Capability::proxy_tap); }); }
  inline int descriptor() const noexcept { return results_.descriptor(); }

  inline void submit(CapturedExchange<Memory> &captured) noexcept {
    TELAR_TRACE("plugins.submitExchange");
    auto owned = std::move(captured);
    if (!listening() || stopped_.load(std::memory_order_acquire)) {
      return;
    }
    auto charged = budget_.charge(SharedExchange<Memory>::capturedBytes(owned));
    if (!charged) {
      return;
    }
    const auto event_id = next_event_.fetch_add(1, std::memory_order_relaxed);
    try {
      auto shared = std::allocate_shared<SharedExchange<Memory>>(AllocatorRef<SharedExchange<Memory>, Memory>{memory_}, std::move(*charged), event_id, std::move(owned));
      for (const auto &worker : workers_) {
        worker->submit(shared);
      }
    } catch (const std::bad_alloc &) {
    }
  }

  template <typename Consumer>
  inline void collect(Consumer &&consumer) {
    results_.collect([&](const auto &result) {
      if (result.package_index < workers_.size() && !workers_[result.package_index]->revoked() && result.authorized(workers_[result.package_index]->specification())) {
        consumer(result.batch());
      }
    });
  }

  inline TapMetrics metrics() const noexcept {
    TapMetrics totals{.dropped_bytes = budget_.dropped()};
    for (const auto &worker : workers_) {
      const auto metrics = worker->metrics();
      totals.dropped_queue += metrics.dropped;
      totals.timeouts += metrics.timeouts;
      totals.disabled += metrics.disabled;
    }
    return totals;
  }

  inline std::size_t heldBytes() const noexcept { return budget_.used(); }

private:
  inline void refreshTrust() noexcept {
    try {
      const auto trust = TrustStore::load(memory_, trust_path_.view());
      for (const auto &worker : workers_) {
        const auto &specification = worker->specification();
        if (!specification.stillAuthorized(trust.granted(specification.name.view(), specification.digest))) { worker->revoke(); }
      }
    } catch (...) {
      // An unreadable, unsafe or invalid store cannot keep an old grant alive.
      for (const auto &worker : workers_) { worker->revoke(); }
    }
  }

  Memory &memory_;
  TapBudget budget_;
  ResultQueue<Memory> results_;
  std::optional<CancellationSignal> cancellation_;
  // Workers report to the queue, budget and cancellation above, so the service is pinned.
  tbc::view<Vector<Owned<Worker<Memory>, Memory>, Memory>, tbc::lt::self> workers_;
  FixedText<PATH_MAX> trust_path_;
  std::jthread trust_monitor_;
  std::atomic<std::uint64_t> next_event_{1};
  std::atomic<bool> stopped_{false};
};

template <ConcurrentAllocator Memory>
Service(Memory &memory, std::span<const ServiceSpec> specifications, const char *executable, std::string_view trace_prefix = {}) -> Service<Memory>;

template <ConcurrentAllocator Memory>
class ShutdownGuard {
public:
  inline explicit ShutdownGuard(Service<Memory> &service) noexcept : service_(service) {}
  inline ~ShutdownGuard() { service_.stop(); }

  ShutdownGuard(const ShutdownGuard &) = delete;
  ShutdownGuard &operator=(const ShutdownGuard &) = delete;

private:
  Service<Memory> &service_;
};

template <ConcurrentAllocator Memory>
ShutdownGuard(Service<Memory> &service) -> ShutdownGuard<Memory>;

}
}
