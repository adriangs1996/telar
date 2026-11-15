module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.plugins.service;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.vocabulary.traffic;

import telar.runtime.plugins.worker;
import telar.base.diagnostics;
import telar.platform.primitives;
import telar.plugins;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.runtime.platform.signals;
import telar.runtime.plugins.tap_configuration;
import telar.runtime.traffic.control_backend;
import telar.runtime.vocabulary.exchange;

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
    concept EventSource = requires(Source& source, void (*consumer)(const EffectBatch&)) {
      { source.descriptor() } noexcept -> std::same_as<int>;
      { source.collect(consumer) } -> std::same_as<void>;
      { source.metrics() } noexcept -> std::same_as<TapMetrics>;
    };

    struct IgnoreEvents {
      constexpr int descriptor() const noexcept {
        return -1;
      }

      constexpr TapMetrics metrics() const noexcept {
        return {};
      }

      // Generic over the caller's consumer.
      template <typename Consumer>
      TBC_GENERIC constexpr void collect(Consumer&&) const noexcept {}
    };

  }
}

// Interface: plugins/service.cppm
export {
  namespace telar::runtime::plugins {

    // Proxy threads submit exchanges and the runtime collects results while the trust monitor revokes
    // workers: the workers are fixed once built, and what changes after is atomic or a synchronized
    // channel, so every borrow the service lends stays valid whatever is done through it.
    class TBC_SHARED Service {
    public:
      explicit Service(ConcurrentMemory& memory, std::span<const ServiceSpec> specifications, const char* executable, std::string_view trace_prefix = {}, traffic::PackagePort* traffic = nullptr);

      ~Service();

      Service(const Service&) = delete;
      Service& operator=(const Service&) = delete;

      void watchTrust(std::string_view path);

      void stop() noexcept;

      bool listening() const noexcept;

      int descriptor() const noexcept;

      void submit(CapturedExchange& captured) noexcept;

      // Generic over the caller's consumer.
      template <typename Consumer>
      TBC_GENERIC void collect(Consumer&& consumer) {
        results_.collect([&](const auto& result) {
          if (result.package_index < workers_.size() && !workers_[result.package_index]->revoked() && result.authorized(workers_[result.package_index]->specification())) {
            consumer(result.batch());
          }
        });
      }

      TapMetrics metrics() const noexcept;

      std::size_t heldBytes() const noexcept;

    private:
      void refreshTrust() noexcept;

      ConcurrentMemory& memory_;
      TapBudget budget_;
      ResultQueue<ConcurrentMemory> results_;
      std::optional<CancellationSignal> cancellation_;
      // Workers report to the queue, budget and cancellation above, so the service is pinned.
      tbc::view<Vector<Owned<Worker<>, ConcurrentMemory>, ConcurrentMemory>, tbc::lt::self> workers_;
      FixedText<PATH_MAX> trust_path_;
      std::jthread trust_monitor_;
      std::atomic<std::uint64_t> next_event_{1};
      std::atomic<bool> stopped_{false};
    };

    class ShutdownGuard {
    public:
      explicit ShutdownGuard(Service& service) noexcept;

      ~ShutdownGuard();

      ShutdownGuard(const ShutdownGuard&) = delete;
      ShutdownGuard& operator=(const ShutdownGuard&) = delete;

    private:
      Service& service_;
    };

  }
}
