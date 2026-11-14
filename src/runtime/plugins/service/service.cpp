module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.plugins.service;

namespace telar::runtime::plugins {

  template <ConcurrentAllocator Memory>
  Service<Memory>::Service(Memory& memory, std::span<const ServiceSpec> specifications, const char* executable, std::string_view trace_prefix, traffic::PackagePort* traffic)
      : memory_(memory),
        workers_(AllocatorRef<Owned<Worker<Memory>, Memory>, Memory>{memory}) {
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
      for (const auto& specification : specifications) {
        workers_.push_back(makeOwned<Worker<Memory>>(memory, memory, specification, results_, budget_, WorkerLaunch{.executable = executable, .cancellation = *cancellation_, .trace_prefix = trace_prefix, .traffic = traffic}));
      }
    } catch (...) {
      stop();
      throw;
    }
  }

  template <ConcurrentAllocator Memory>
  Service<Memory>::~Service() {
    stop();
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::watchTrust(std::string_view path) {
    if (workers_.empty()) {
      return;
    }

    if (stopped_.load(std::memory_order_acquire) || trust_monitor_.joinable() || path.empty()) {
      throw std::invalid_argument{"Invalid plugin trust monitor"};
    }

    trust_path_.assign(path);
    refreshTrust();
    trust_monitor_ = std::jthread{[this] {
      pollfd wake{cancellation_->descriptor(), POLLIN, 0};

      while (!cancellation_->requested()) {
        const auto ready = ::poll(&wake, 1, static_cast<int>(Limits::trust_check_interval.count()));
        if (ready < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (ready != 0) {
          return;
        }

        refreshTrust();
      }
    }};
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::stop() noexcept {
    if (stopped_.exchange(true, std::memory_order_acq_rel)) {
      return;
    }

    if (cancellation_) {
      cancellation_->request();
    }

    if (trust_monitor_.joinable()) {
      trust_monitor_.join();
    }

    for (const auto& worker : workers_) {
      worker->stop();
    }

    results_.close();
  }

  template <ConcurrentAllocator Memory>
  bool Service<Memory>::listening() const noexcept {
    return std::ranges::any_of(workers_, [](const auto& worker) {
      return !worker->revoked() && worker->specification().allows(Capability::proxy_tap);
    });
  }

  template <ConcurrentAllocator Memory>
  int Service<Memory>::descriptor() const noexcept {
    return results_.descriptor();
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::submit(CapturedExchange<Memory>& captured) noexcept {
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

      for (const auto& worker : workers_) {
        worker->submit(shared);
      }
    } catch (const std::bad_alloc&) {
    }
  }

  template <ConcurrentAllocator Memory>
  TapMetrics Service<Memory>::metrics() const noexcept {
    TapMetrics totals{.dropped_bytes = budget_.dropped()};

    for (const auto& worker : workers_) {
      const auto metrics = worker->metrics();

      totals.dropped_queue += metrics.dropped;
      totals.timeouts += metrics.timeouts;
      totals.disabled += metrics.disabled;
    }

    return totals;
  }

  template <ConcurrentAllocator Memory>
  std::size_t Service<Memory>::heldBytes() const noexcept {
    return budget_.used();
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::refreshTrust() noexcept {
    try {
      const auto trust = TrustStore::load(memory_, trust_path_.view());

      for (const auto& worker : workers_) {
        const auto& specification = worker->specification();
        if (!specification.stillAuthorized(trust.granted(specification.name.view(), specification.digest))) {
          worker->revoke();
        }
      }
    } catch (...) {
      // An unreadable, unsafe or invalid store cannot keep an old grant alive.
      for (const auto& worker : workers_) {
        worker->revoke();
      }
    }
  }

  template <ConcurrentAllocator Memory>
  ShutdownGuard<Memory>::ShutdownGuard(Service<Memory>& service) noexcept
      : service_(service) {}

  template <ConcurrentAllocator Memory>
  ShutdownGuard<Memory>::~ShutdownGuard() {
    service_.stop();
  }

  template class Service<ConcurrentMemory>;
  template class ShutdownGuard<ConcurrentMemory>;

}
