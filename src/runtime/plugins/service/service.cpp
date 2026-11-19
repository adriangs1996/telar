module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.plugins.service;

import telar.platform.primitives;
import telar.plugins;

namespace telar::runtime::plugins {

  Service::Service(ConcurrentMemory& memory, std::span<const ServiceSpec> specifications, const char* executable, std::string_view trace_prefix, traffic::PackagePort* traffic)
      : memory_(memory),
        workers_(memory) {
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
        workers_.push(ds::makeBox<Worker<>>(memory, memory, specification, results_, budget_, WorkerLaunch{.executable = executable, .cancellation = cancellation_.getMut(), .trace_prefix = trace_prefix, .traffic = traffic}));
      }
    } catch (...) {
      stop();
      throw;
    }
  }

  Service::~Service() {
    stop();
  }

  void Service::watchTrust(std::string_view path) {
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

  void Service::stop() noexcept {
    if (stopped_.exchange(true, std::memory_order_acq_rel)) {
      return;
    }

    if (cancellation_) {
      cancellation_.getMut().request();
    }

    if (trust_monitor_.joinable()) {
      trust_monitor_.join();
    }

    for (auto& worker : workers_.viewMut()) {
      worker.getMut().stop();
    }

    results_.close();
  }

  bool Service::listening() const noexcept {
    return std::ranges::any_of(workers_, [](const auto& worker) {
      return !worker->revoked() && worker->specification().allows(Capability::proxy_tap);
    });
  }

  int Service::descriptor() const noexcept {
    return results_.descriptor();
  }

  void Service::submit(CapturedExchange& captured) noexcept {
    TELAR_TRACE("plugins.submitExchange");
    auto owned = std::move(captured);

    if (!listening() || stopped_.load(std::memory_order_acquire)) {
      return;
    }

    auto charged = budget_.charge(SharedExchange::capturedBytes(owned));
    if (!charged) {
      return;
    }

    const auto event_id = next_event_.fetch_add(1, std::memory_order_relaxed);

    try {
      auto shared = std::allocate_shared<SharedExchange>(AllocatorRef<SharedExchange, ConcurrentMemory>{memory_}, std::move(charged.getMut()), event_id, std::move(owned));

      for (auto& worker : workers_.viewMut()) {
        worker.getMut().submit(shared);
      }
    } catch (const std::bad_alloc&) {
    }
  }

  TapMetrics Service::metrics() const noexcept {
    TapMetrics totals{.dropped_bytes = budget_.dropped()};

    for (const auto& worker : workers_) {
      const auto metrics = worker->metrics();

      totals.dropped_queue += metrics.dropped;
      totals.timeouts += metrics.timeouts;
      totals.disabled += metrics.disabled;
    }

    return totals;
  }

  std::size_t Service::heldBytes() const noexcept {
    return budget_.used();
  }

  void Service::refreshTrust() noexcept {
    try {
      const auto trust = TrustStore::load(memory_, trust_path_.view());

      for (auto& worker : workers_.viewMut()) {
        const auto& specification = worker->specification();
        if (!specification.stillAuthorized(trust.granted(specification.name.view(), specification.digest))) {
          worker.getMut().revoke();
        }
      }
    } catch (...) {
      // An unreadable, unsafe or invalid store cannot keep an old grant alive.
      for (auto& worker : workers_.viewMut()) {
        worker.getMut().revoke();
      }
    }
  }

  ShutdownGuard::ShutdownGuard(Service& service) noexcept
      : service_(service) {}

  ShutdownGuard::~ShutdownGuard() {
    service_.stop();
  }

}
