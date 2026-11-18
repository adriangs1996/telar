module;
#include "tbc/annotations.hpp"

export module telar.runtime.plugins.tap_configuration;

import std;
import telar.lua;
import telar.sys.posix;

import telar.config.client;
import telar.plugins;

import telar.platform.fs;
import telar.platform.paths;

import telar.runtime.vocabulary.exchange;
import telar.runtime.vocabulary.traffic;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.platform.error;
import telar.base.text;
import telar.base.memory.allocators;
import telar.platform.net;
import telar.base.ds;

// Interface: plugins/action_encoder.cppm
export {
  namespace telar::runtime::plugins {

    class ActionEncoder {
    public:
      explicit ActionEncoder(const config::RetainedActionValidator& validator);

      std::span<const Byte> encode(const lua::Value& result);

    private:
      bool append(const lua::Value& value, std::span<Byte>& output) const;

      static void tag(ActionTag value, std::span<Byte>& output);

      static void directional(std::string_view name, std::string_view direction, std::span<Byte>& output);

      static void builtin(std::string_view name, std::span<Byte>& output);

      static void text(std::string_view value, std::span<Byte>& output);

      static void notification(const lua::Value& value, std::span<Byte>& output);

      const config::RetainedActionValidator& validator_;
      std::array<Byte, ActionProtocol::maximum_bytes> storage_;
    };

  }
}

// Interface: plugins/package_snapshots.cppm
export {
  namespace telar::runtime::plugins {

    template <Allocator Memory>
    class PackageSnapshots {
    public:
      explicit PackageSnapshots(Memory& memory) noexcept;

      Package copy(const Package& package, std::size_t index);

      std::string_view path() const noexcept;

    private:
      Memory& memory_;
      ds::Option<TemporaryDirectory> directory_;
    };

    extern template class PackageSnapshots<Memory>;
    extern template class PackageSnapshots<ConcurrentMemory>;

  }
}

// Interface: plugins/pipe_stream.cppm
export {
  namespace telar::runtime::plugins {

    template <typename Wait>
    concept PipeWait = requires(Wait& wait, int descriptor, short events) {
      { wait.active() } noexcept -> std::same_as<bool>;
      { wait.ready(descriptor, events) } noexcept -> std::same_as<bool>;
    };

    struct BlockingPipeWait {
      constexpr bool active() const noexcept {
        return true;
      }

      constexpr bool ready(int, short) const noexcept {
        return true;
      }
    };

    // Generic over the caller's wait, and called for every frame a tap worker exchanges.
    template <PipeWait Wait = BlockingPipeWait>
    class TBC_GENERIC PipeStream {
    public:
      inline explicit PipeStream(int input, int output, Wait wait = {}) noexcept
          : input_(input),
            output_(output),
            wait_(std::move(wait)) {}

      inline Wait& waitMut() noexcept {
        return wait_;
      }

      inline const Wait& wait() const noexcept {
        return wait_;
      }

      inline StreamResult read(std::span<std::uint8_t> destination) noexcept {
        while (wait_.active()) {
          const auto count = ::read(input_, destination.data(), destination.size());
          if (count < 0 && sys::lastError() == EINTR) {
            continue;
          }

          if (count < 0 && (sys::lastError() == EAGAIN || sys::lastError() == EWOULDBLOCK) && wait_.ready(input_, POLLIN)) {
            continue;
          }

          if (count < 0) {
            return {StreamResult::State::failed};
          }

          if (count == 0) {
            return {StreamResult::State::ended};
          }

          return {StreamResult::State::data, static_cast<std::size_t>(count)};
        }

        return {StreamResult::State::failed};
      }

      inline void write(std::span<const std::uint8_t> prefix, std::span<const std::uint8_t> payload) {
        std::array vectors{
            iovec{const_cast<std::uint8_t*>(prefix.data()), prefix.size()},
            iovec{const_cast<std::uint8_t*>(payload.data()), payload.size()},
        };

        std::size_t first = 0;

        while (first < vectors.size()) {
          if (!wait_.active()) {
            throw SystemError{"Wait for tap pipe"};
          }

          const auto count = ::writev(output_, vectors.data() + first, static_cast<int>(vectors.size() - first));
          if (count < 0 && sys::lastError() == EINTR) {
            continue;
          }

          if (count < 0 && (sys::lastError() == EAGAIN || sys::lastError() == EWOULDBLOCK) && wait_.ready(output_, POLLOUT)) {
            continue;
          }

          if (count <= 0) {
            throw SystemError{"Write tap frame", count == 0 ? EPIPE : sys::lastError()};
          }

          auto consumed = static_cast<std::size_t>(count);

          while (first < vectors.size() && consumed >= vectors[first].iov_len) {
            consumed -= vectors[first].iov_len;
            ++first;
          }

          if (first < vectors.size()) {
            vectors[first].iov_base = static_cast<std::uint8_t*>(vectors[first].iov_base) + consumed;
            vectors[first].iov_len -= consumed;
          }
        }
      }

    private:
      int input_;
      int output_;
      Wait wait_;
    };

    template <PipeWait Wait = BlockingPipeWait>
    PipeStream(int input, int output, Wait wait = {}) -> PipeStream<Wait>;

  }
}

// Interface: plugins/restart_window.cppm
export {
  namespace telar::runtime::plugins {

    class RestartWindow {
    public:
      bool record(std::chrono::milliseconds now) noexcept;

    private:
      std::array<std::chrono::milliseconds, Limits::restarts> restarts_;
      std::size_t count_ = 0;
    };

  }
}

// Interface: plugins/tap_budget.cppm
export {
  namespace telar::runtime::plugins {

    class TapBudget {
    public:
      class Charge {
      public:
        explicit Charge(CaptureQuota& quota, std::size_t bytes) noexcept;

        ~Charge();

        Charge(const Charge&) = delete;
        Charge& operator=(const Charge&) = delete;

        Charge(Charge&& other) noexcept;

      private:
        CaptureQuota& quota_;
        std::size_t bytes_;
      };

      explicit TapBudget(std::size_t limit = Limits::held_bytes) noexcept;

      ds::Option<Charge> charge(std::size_t bytes) noexcept;

      std::size_t used() const noexcept;

      std::uint64_t dropped() const noexcept;

    private:
      CaptureQuota quota_;
      std::atomic<std::uint64_t> dropped_{0};
    };

  }
}

// Interface: plugins/shared_exchange.cppm
export {
  namespace telar::runtime::plugins {

    struct SharedExchange {
      explicit SharedExchange(TapBudget::Charge charge, std::uint64_t event_id, CapturedExchange exchange) noexcept;

      static std::size_t capturedBytes(const CapturedExchange& exchange) noexcept;

      TapBudget::Charge charge;
      std::uint64_t event_id;
      CapturedExchange exchange;
    };

  }
}

// Interface: plugins/tap_configuration.cppm
export {
  namespace telar::runtime::plugins {

    template <Allocator Memory>
    class TapConfiguration {
    public:
      // Generic over the caller's environment.
      template <EnvironmentLookup Environment>
      TBC_GENERIC explicit TapConfiguration(Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> configured, const Environment& environment)
          : snapshots_(memory) {
        if (directory.empty()) {
          return;
        }

        const auto trust = loadTrust(memory, environment);
        const PackageRegistry registry{memory, directory, configured};

        for (const auto& package : registry.packages()) {
          const auto granted = trust.granted(package.manifest.id.view(), package.digest);
          const auto allowed = [&](Capability capability) {
            return package.manifest.capabilities.contains(capability) && granted.contains(capability);
          };
          if (!allowed(Capability::proxy_tap) && std::ranges::none_of(ServiceSpec::traffic_capabilities, allowed)) {
            continue;
          }

          if (count_ == specifications_.size()) {
            throw std::invalid_argument{"Too many tap plugins"};
          }

          const auto copied = snapshots_.copy(package, count_);
          auto& specification = specifications_[count_];

          specification.package_index = static_cast<std::uint8_t>(count_);
          specification.plugin_id = stableId(copied.manifest.id.view());
          specification.digest = copied.digest;
          specification.generation = initial_generation;
          specification.name = copied.manifest.id;
          specification.declared = copied.manifest.capabilities;
          specification.granted = granted;
          String<Memory> entry{copied.root.view(), AllocatorRef<char, Memory>{memory}};

          entry += '/';
          entry += copied.manifest.entry.view();
          specification.entry.assign(entry);
          ++count_;
        }
      }

      std::span<const ServiceSpec> specifications() const noexcept;

    private:
      template <EnvironmentLookup Environment>
      TBC_GENERIC static TrustStore loadTrust(Memory& memory, const Environment& environment) {
        return TrustStore::load(memory, Paths::trust(memory, environment));
      }

      static constexpr std::uint64_t initial_generation = 1;
      PackageSnapshots<Memory> snapshots_;
      std::array<ServiceSpec, Limits::workers> specifications_;
      std::size_t count_ = 0;
    };

    extern template class TapConfiguration<Memory>;
    extern template class TapConfiguration<ConcurrentMemory>;

    template <Allocator Memory, EnvironmentLookup Environment>
    TapConfiguration(Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> configured, const Environment& environment) -> TapConfiguration<Memory>;

  }
}
