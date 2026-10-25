#pragma once

#include "restart_window.hpp"
#include "result_queue.hpp"
#include "session.hpp"
#include "shared_exchange.hpp"
#include <thread>

namespace telar::runtime::plugins {

struct WorkerLaunch {
  const char *executable;
  CancellationSignal &cancellation;
  std::chrono::milliseconds timeout = Limits::reply_deadline;
  std::string_view trace_prefix{};
};

struct WorkerMetrics {
  std::uint64_t dropped = 0;
  std::uint64_t timeouts = 0;
  bool disabled = false;
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
      : memory_(memory), specification_(specification), results_(results), budget_(budget), launch_(launch), entry_(specification.entry.view(), AllocatorRef<char, Memory>{memory}), trace_path_(AllocatorRef<char, Memory>{memory}), thread_([this] { run(); }) {}

  ~Worker() { stop(); }

  void stop() noexcept {
    launch_.cancellation.request();
    requests_.close();
    if (thread_.joinable()) {
      thread_.join();
    }
    session_.reset();
  }

  void submit(Shared exchange) noexcept {
    if (!disabled_.load(std::memory_order_relaxed)) {
      requests_.publish(std::move(exchange));
    }
  }

  WorkerMetrics metrics() const noexcept {
    return {requests_.metrics().dropped, timeouts_.load(std::memory_order_relaxed), disabled_.load(std::memory_order_relaxed)};
  }

  const ServiceSpec &specification() const noexcept { return specification_; }

private:
  void run() noexcept {
    while (auto request = requests_.receive()) {
      if (!disabled_.load(std::memory_order_relaxed)) {
        process(**request);
      }
    }
  }

  void process(const SharedExchange<Memory> &shared) noexcept {
    TELAR_TRACE("plugins.processExchange");
    try {
      if (!session_) {
        prepareTrace();
        session_.emplace(memory_, SessionOptions{.executable = launch_.executable, .entry = entry_.c_str(), .cancellation = launch_.cancellation, .timeout = launch_.timeout, .trace_path = trace_path_.empty() ? nullptr : trace_path_.c_str()});
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
  std::optional<Session<Memory>> session_;
  RestartWindow restarts_;
  std::atomic<std::uint64_t> timeouts_{0};
  std::atomic<bool> disabled_{false};
  std::jthread thread_;
};

}
