#pragma once

#include "../platform/thread_name.hpp"

#include "../diagnostics/trace.hpp"
#include "../platform/completion_signal.hpp"
#include "system_resolver.hpp"
#include "telar_config/proxy/hostname.hpp"
#include <algorithm>
#include <concepts>
#include <pthread.h>
#include <type_traits>
#include <utility>

namespace telar::runtime {

template <typename Resolver>
concept HostnameResolver = requires(const char *hostname, std::span<NetworkAddress> addresses) {
  { Resolver::resolve(hostname, addresses) } noexcept -> std::same_as<ResolutionSummary>;
};

template <HostnameResolver Resolver>
class NameResolutions {
public:
  static constexpr std::size_t capacity = 64;
  static constexpr std::size_t maximum_addresses = 32;

  struct Result {
    std::array<NetworkAddress, maximum_addresses> addresses;
    ResolutionSummary summary;
  };

private:
  enum class Phase {
    free,
    resolving,
    resolved
  };

  struct Row {
    Phase phase = Phase::free;
    std::array<char, ProxyHostname::maximum_bytes + 1> hostname{};
    std::size_t length = 0;
    std::size_t waiters = 0;
    Result result;
  };

  static constexpr std::size_t maximum_subscribers = 128;

  struct State {
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    std::array<Row, capacity> rows;
    std::array<CompletionSignal *, maximum_subscribers> subscribers{};
  };

  class Lock {
  public:
    Lock() noexcept {
      ::pthread_mutex_lock(&state_.mutex);
    }

    ~Lock() {
      ::pthread_mutex_unlock(&state_.mutex);
    }

    Lock(const Lock &) = delete;
    Lock &operator=(const Lock &) = delete;
  };

public:
  class Ticket {
  public:
    ~Ticket() {
      reset();
    }

    Ticket(const Ticket &) = delete;
    Ticket &operator=(const Ticket &) = delete;

    Ticket(Ticket &&other) noexcept
        : index_(std::exchange(other.index_, capacity)) {}

    Ticket &operator=(Ticket &&other) noexcept {
      if (this != &other) {
        reset();
        index_ = std::exchange(other.index_, capacity);
      }
      return *this;
    }

    bool collect(Result &result) const noexcept {
      const Lock lock;
      if (index_ == capacity || state_.rows[index_].phase != Phase::resolved) {
        return false;
      }

      const auto &stored = state_.rows[index_].result;
      result.summary = stored.summary;
      if (stored.summary.error == 0) {
        std::copy_n(stored.addresses.begin(), std::min(stored.summary.found, maximum_addresses), result.addresses.begin());
      }
      return true;
    }

    void reset() noexcept {
      if (index_ == capacity) {
        return;
      }

      const Lock lock;
      auto &row = state_.rows[std::exchange(index_, capacity)];
      if (--row.waiters == 0 && row.phase == Phase::resolved) {
        row.phase = Phase::free;
      }
    }

  private:
    friend class NameResolutions;

    explicit Ticket(std::size_t index) noexcept
        : index_(index) {}

    std::size_t index_;
  };

  class Notifications {
  public:
    explicit Notifications(CompletionSignal &signal) {
      const Lock lock;
      const auto available = std::ranges::find(state_.subscribers, nullptr);
      if (available == state_.subscribers.end()) {
        throw SystemError{"Too many proxy resolver subscribers", ENOSPC};
      }
      *available = &signal;
      index_ = static_cast<std::size_t>(available - state_.subscribers.begin());
    }

    ~Notifications() {
      const Lock lock;
      state_.subscribers[index_] = nullptr;
    }

    Notifications(const Notifications &) = delete;
    Notifications &operator=(const Notifications &) = delete;

  private:
    std::size_t index_;
  };

  static std::optional<Ticket> request(std::string_view hostname) noexcept {
    if (!ProxyHostname::validTarget(hostname)) {
      return std::nullopt;
    }

    const Lock lock;
    std::optional<std::size_t> available;
    for (std::size_t index = 0; index < state_.rows.size(); ++index) {
      auto &row = state_.rows[index];
      if (row.phase == Phase::free) {
        if (!available) {
          available = index;
        }
      } else if (row.length == hostname.size() && std::equal(hostname.begin(), hostname.end(), row.hostname.begin(), [](char first, char second) { return asciiLower(first) == asciiLower(second); })) {
        ++row.waiters;
        return Ticket{index};
      }
    }
    if (!available) {
      return std::nullopt;
    }

    auto &row = state_.rows[*available];
    row.phase = Phase::resolving;
    row.length = hostname.size();
    std::copy(hostname.begin(), hostname.end(), row.hostname.begin());
    row.hostname[row.length] = '\0';
    row.waiters = 1;
    if (const auto error = start(row); error != 0) {
      row.result.summary = {.error = EAI_MEMORY};
      row.phase = Phase::resolved;
      notify();
    }
    return Ticket{*available};
  }

  static std::size_t pending() noexcept {
    const Lock lock;
    return std::ranges::count_if(state_.rows, [](const auto &row) { return row.phase == Phase::resolving; });
  }

private:
  static int start(Row &row) noexcept {
    pthread_attr_t attributes;
    const int initialized = ::pthread_attr_init(&attributes);
    if (initialized != 0) {
      return initialized;
    }

    int error = ::pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (error == 0) {
      error = ::pthread_attr_setstacksize(&attributes, worker_stack_bytes);
    }
    if (error == 0) {
      pthread_t thread;
      error = ::pthread_create(&thread, &attributes, &resolve, &row);
    }
    ::pthread_attr_destroy(&attributes);
    return error;
  }

  static void *resolve(void *context) noexcept {
    setThreadName("telar.proxy.dns");
    auto &row = *static_cast<Row *>(context);
#if TELAR_DEBUG
    const auto started = trace::now();
#endif
    const auto summary = Resolver::resolve(row.hostname.data(), row.result.addresses);
    const Lock lock;
    if (row.waiters == 0) {
      row.phase = Phase::free;
      return nullptr;
    }

    row.result.summary = summary;
    row.phase = Phase::resolved;
#if TELAR_DEBUG
    trace::record("proxy.resolveHostname", started, trace::now());
#endif
    notify();
    return nullptr;
  }

  static void notify() noexcept {
    for (auto *subscriber : state_.subscribers) {
      if (subscriber != nullptr) {
        subscriber->notify();
      }
    }
  }

  static constexpr std::size_t worker_stack_bytes = 512 * 1024;
  // Detached system resolver calls may outlive every proxy. Their rows have
  // process lifetime and never borrow a runtime allocator or service object.
  inline static constinit State state_;
  static_assert(std::is_trivially_destructible_v<State>);
};

}
