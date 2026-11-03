#pragma once

#include "event_source.hpp"
#include "telar_plugins/trust_store.hpp"
#include "worker.hpp"

namespace telar::runtime::plugins {

template <ConcurrentAllocator Memory>
class Service {
public:
  explicit Service(Memory &memory, std::span<const ServiceSpec> specifications, const char *executable, std::string_view trace_prefix = {}, traffic::PackagePort *traffic = nullptr)
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

  ~Service() { stop(); }

  void watchTrust(std::string_view path) {
    if (workers_.empty()) { return; }
    if (stopped_ || trust_monitor_.joinable() || path.empty()) { throw std::invalid_argument{"Invalid plugin trust monitor"}; }
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

  void stop() noexcept {
    if (stopped_) {
      return;
    }
    stopped_ = true;
    if (cancellation_) {
      cancellation_->request();
    }
    if (trust_monitor_.joinable()) { trust_monitor_.join(); }
    for (const auto &worker : workers_) {
      worker->stop();
    }
    results_.close();
  }

  bool listening() const noexcept { return std::ranges::any_of(workers_, [](const auto &worker) { return !worker->revoked() && worker->specification().allows(Capability::proxy_tap); }); }
  int descriptor() const noexcept { return results_.descriptor(); }

  void submit(CapturedExchange<Memory> &captured) noexcept {
    TELAR_TRACE("plugins.submitExchange");
    auto owned = std::move(captured);
    if (!listening() || stopped_) {
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
  void collect(Consumer &&consumer) {
    results_.collect([&](const auto &result) {
      if (result.package_index < workers_.size() && !workers_[result.package_index]->revoked() && result.authorized(workers_[result.package_index]->specification())) {
        consumer(result.batch);
      }
    });
  }

  TapMetrics metrics() const noexcept {
    TapMetrics totals{.dropped_bytes = budget_.dropped()};
    for (const auto &worker : workers_) {
      const auto metrics = worker->metrics();
      totals.dropped_queue += metrics.dropped;
      totals.timeouts += metrics.timeouts;
      totals.disabled += metrics.disabled;
    }
    return totals;
  }

  std::size_t heldBytes() const noexcept { return budget_.used(); }

private:
  void refreshTrust() noexcept {
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
  Vector<Owned<Worker<Memory>, Memory>, Memory> workers_;
  FixedText<PATH_MAX> trust_path_;
  std::jthread trust_monitor_;
  std::atomic<std::uint64_t> next_event_{1};
  bool stopped_ = false;
};

template <ConcurrentAllocator Memory>
Service(Memory &memory, std::span<const ServiceSpec> specifications, const char *executable, std::string_view trace_prefix = {}) -> Service<Memory>;

template <ConcurrentAllocator Memory>
class ShutdownGuard {
public:
  explicit ShutdownGuard(Service<Memory> &service) noexcept : service_(service) {}
  ~ShutdownGuard() { service_.stop(); }

  ShutdownGuard(const ShutdownGuard &) = delete;
  ShutdownGuard &operator=(const ShutdownGuard &) = delete;

private:
  Service<Memory> &service_;
};

template <ConcurrentAllocator Memory>
ShutdownGuard(Service<Memory> &service) -> ShutdownGuard<Memory>;

}
