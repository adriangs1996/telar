#pragma once

#include "restart_window.hpp"
#include "result_queue.hpp"
#include "session.hpp"
#include "shared_exchange.hpp"
#include "traffic_bridge.hpp"
#include <thread>

namespace telar::runtime::plugins {

struct WorkerLaunch {
  const char *executable;
  CancellationSignal &cancellation;
  std::chrono::milliseconds timeout = Limits::reply_deadline;
  std::string_view trace_prefix{};
  traffic::PackagePort *traffic = nullptr;
};

struct WorkerMetrics {
  std::uint64_t dropped = 0;
  std::uint64_t timeouts = 0;
  bool disabled = false;
  std::uint64_t callback_errors = 0;
};

template <typename Clock>
concept WorkerClock = requires {
  { Clock::now() } noexcept -> std::same_as<typename Clock::time_point>;
};

template <ConcurrentAllocator Memory, WorkerClock Clock = std::chrono::steady_clock>
class Worker {
public:
  using Shared = std::shared_ptr<SharedExchange<Memory>>;

  explicit Worker(Memory &memory, const ServiceSpec &specification, ResultQueue<Memory> &results, TapBudget &budget, WorkerLaunch launch)
      : memory_(memory), specification_(bindPermissions(memory, specification)), results_(results), budget_(budget), launch_(launch), entry_(specification.entry.view(), AllocatorRef<char, Memory>{memory}), trace_path_(AllocatorRef<char, Memory>{memory}), thread_([this] { run(); }) {}

  ~Worker() { stop(); }

  void stop() noexcept {
    cancellation_.request();
    requests_.close();
    if (thread_.joinable()) {
      thread_.join();
    }
    bridge_.reset();
    session_.reset();
  }

  void revoke() noexcept {
    specification_.permission->store(false, std::memory_order_release);
    if (revoked_.exchange(true, std::memory_order_acq_rel)) { return; }
    disabled_.store(true, std::memory_order_relaxed);
    cancellation_.request();
    requests_.close();
    if (launch_.traffic) { launch_.traffic->revokePackage(specification_); }
  }

  bool revoked() const noexcept { return revoked_.load(std::memory_order_acquire); }

  void submit(Shared exchange) noexcept {
    if (specification_.allows(Capability::proxy_tap) && !disabled_.load(std::memory_order_relaxed)) {
      requests_.publish(std::move(exchange));
      wake_.notify();
    }
  }

  WorkerMetrics metrics() const noexcept {
    return {requests_.metrics().dropped, timeouts_.load(std::memory_order_relaxed), disabled_.load(std::memory_order_relaxed), callback_errors_.load(std::memory_order_relaxed)};
  }

  const ServiceSpec &specification() const noexcept { return specification_; }

private:
  static ServiceSpec bindPermissions(Memory &memory, const ServiceSpec &specification) {
    auto bound = specification;
    if (!bound.permission) { bound.permission = std::allocate_shared<std::atomic<bool>>(AllocatorRef<std::atomic<bool>, Memory>{memory}, true); }
    return bound;
  }

  void run() noexcept {
    if (launch_.traffic && specification_.traffic()) {
      runTraffic();
    } else {
      while (auto request = requests_.receive()) {
        if (!disabled_.load(std::memory_order_relaxed)) {
          process(**request);
        }
      }
    }

    if (revoked() || cancellation_.requested() || launch_.cancellation.requested()) {
      bridge_.reset();
      session_.reset();
    }
  }

  void runTraffic() noexcept {
    while (!launch_.cancellation.requested() && !cancellation_.requested()) {
      if (disabled_.load(std::memory_order_relaxed)) {
        std::array watches{pollfd{cancellation_.descriptor(), POLLIN, 0}, pollfd{launch_.cancellation.descriptor(), POLLIN, 0}};
        if (::poll(watches.data(), watches.size(), -1) < 0 && errno != EINTR) { return; }
        continue;
      }
      try {
        if (!session_) {
          prepareTrace();
          session_.emplace(memory_, SessionOptions{.executable = launch_.executable, .entry = entry_.c_str(), .cancellation = cancellation_, .timeout = launch_.timeout, .trace_path = trace_path_.empty() ? nullptr : trace_path_.c_str(), .traffic = true});
          if (bridge_) { bridge_->attach(*session_); }
          else { bridge_ = makeOwned<TrafficBridge<Memory>>(memory_, memory_, specification_, *launch_.traffic, *session_); }
        }
        wake_.drain();
        if (auto request = requests_.tryReceive()) { process(**request); }
        if (!bridge_) { continue; }
        bridge_->step(wake_.descriptor(), cancellation_, [&](SensitiveAllocation<Memory> storage, EffectReply reply) {
          results_.publish(makeOwned<Result<Memory>>(memory_, specification_, std::move(storage), reply, true));
        }, requests_.metrics().queued != 0);
        callback_errors_.store(callback_errors_base_ + bridge_->errors(), std::memory_order_relaxed);
      } catch (const SystemError &error) {
        if (error.code() == ECANCELED) { return; }
        if (error.code() == ETIMEDOUT) { timeouts_.fetch_add(1, std::memory_order_relaxed); }
        restart();
      } catch (...) { restart(); }
    }
  }

  void process(const SharedExchange<Memory> &shared) noexcept {
    TELAR_TRACE("plugins.processExchange");
    try {
      if (!session_) {
        prepareTrace();
        session_.emplace(memory_, SessionOptions{.executable = launch_.executable, .entry = entry_.c_str(), .cancellation = cancellation_, .timeout = launch_.timeout, .trace_path = trace_path_.empty() ? nullptr : trace_path_.c_str()});
      }
    } catch (...) {
      restart();
      return;
    }

    try {
      const auto size = SharedExchange<Memory>::capturedBytes(shared.exchange) + Limits::frame_overhead;
      auto charged = budget_.charge(size);
      if (!charged) {
        return;
      }
      const auto encoded_size = Protocol::exchangeBytes(shared.exchange);
      if (encoded_size > size) {
        return;
      }
      SensitiveAllocation frame{memory_, encoded_size};
      const auto payload = Protocol::encodeExchange(frame.bytes(), {shared.event_id, specification_.generation}, shared.exchange);
      exchange(shared.event_id, payload);
    } catch (...) {
    }
  }

  void exchange(std::uint64_t event_id, std::span<const Byte> payload) noexcept {
    try {
      auto result = session_->exchange(specification_, event_id, payload);
      if (result) {
        results_.publish(std::move(result));
      }
    } catch (const SystemError &error) {
      if (error.code() == ECANCELED) {
        return;
      }
      if (error.code() == ETIMEDOUT) {
        timeouts_.fetch_add(1, std::memory_order_relaxed);
      }
      restart();
    } catch (...) {
      restart();
    }
  }

  void restart() noexcept {
    if (bridge_) {
      bridge_->detach();
      if (bridge_->transportFailed()) { callback_errors_base_ += bridge_->errors(); bridge_.reset(); }
    }
    session_.reset();
    const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch());
    if (restarts_.record(now)) {
      disabled_.store(true, std::memory_order_relaxed);
    }
  }

  void prepareTrace() {
#if TELAR_DEBUG
    if (launch_.trace_prefix.empty()) {
      return;
    }
    std::array<char, 64> suffix;
    const auto length = std::snprintf(suffix.data(), suffix.size(), ".tap-%u-%llu.json", static_cast<unsigned>(specification_.package_index), static_cast<unsigned long long>(session_number_++));
    trace_path_ = launch_.trace_prefix;
    trace_path_.append(suffix.data(), static_cast<std::size_t>(length));
#endif
  }

  Memory &memory_;
  ServiceSpec specification_;
  ResultQueue<Memory> &results_;
  TapBudget &budget_;
  WorkerLaunch launch_;
  String<Memory> entry_;
  String<Memory> trace_path_;
  [[maybe_unused]] std::uint64_t session_number_ = 0;
  DropChannel<Shared, Limits::queue_depth, ChannelPolicy::keep_newest> requests_;
  CancellationSignal cancellation_;
  std::optional<Session<Memory>> session_;
  Owned<TrafficBridge<Memory>, Memory> bridge_{nullptr, AllocationDeleter<TrafficBridge<Memory>, Memory>{memory_}};
  CompletionSignal wake_;
  std::uint64_t callback_errors_base_ = 0;
  RestartWindow restarts_;
  std::atomic<std::uint64_t> timeouts_{0};
  std::atomic<bool> disabled_{false};
  std::atomic<bool> revoked_{false};
  std::atomic<std::uint64_t> callback_errors_{0};
  std::jthread thread_;
};

}
