#pragma once

#include "completion_signal.hpp"
#include <atomic>
#include <concepts>
#include <condition_variable>
#include <optional>
#include <pthread.h>

namespace telar::runtime {

template <typename Service>
concept ObservationService = requires(Service &service, const typename Service::Request &request) {
  { service.observe(request) } noexcept -> std::same_as<typename Service::Result>;
  { service.stop() } noexcept -> std::same_as<void>;
};

template <ObservationService Service>
class ObservationWorker {
public:
  explicit ObservationWorker(Service &service, CompletionSignal *completion = nullptr)
      : service_(service),
        completion_(completion) {
    const auto error = ::pthread_create(&thread_, nullptr, &start, this);
    if (error != 0) {
      throw SystemError{"Start observation worker", error};
    }
  }

  ~ObservationWorker() {
    {
      const std::lock_guard lock{mutex_};
      stopping_ = true;
    }
    service_.stop();
    ready_.notify_one();
    ::pthread_join(thread_, nullptr);
  }

  ObservationWorker(const ObservationWorker &) = delete;
  ObservationWorker &operator=(const ObservationWorker &) = delete;

  bool submit(const typename Service::Request &request) {
    const std::lock_guard lock{mutex_};
    if (busy_ || stopping_) {
      return false;
    }
    request_ = request;
    busy_ = true;
    ready_.notify_one();
    return true;
  }

  template <typename Consumer>
  void collect(Consumer &&consume) {
    if (!result_ready_.load(std::memory_order_acquire)) {
      return;
    }

    std::optional<typename Service::Result> result;
    {
      const std::unique_lock lock{mutex_, std::try_to_lock};
      if (!lock.owns_lock()) {
        return;
      }

      result = std::move(result_);
      result_.reset();
      busy_ = false;
      result_ready_.store(false, std::memory_order_relaxed);
    }

    signal_.drain();
    consume(*result);
  }

  int descriptor() const noexcept {
    return signal_.descriptor();
  }

  template <typename Consumer>
  void wait(Consumer &&consume) {
    std::optional<typename Service::Result> result;
    {
      std::unique_lock lock{mutex_};
      if (!busy_) {
        return;
      }

      completed_.wait(lock, [&] { return result_.has_value(); });
      result = std::move(result_);
      result_.reset();
      busy_ = false;
      result_ready_.store(false, std::memory_order_relaxed);
    }

    signal_.drain();
    consume(*result);
  }

private:
  static void *start(void *context) noexcept {
    static_cast<ObservationWorker *>(context)->run();
    return nullptr;
  }

  void run() noexcept {
    for (;;) {
      std::optional<typename Service::Request> request;
      {
        std::unique_lock lock{mutex_};
        ready_.wait(lock, [&] { return stopping_ || request_.has_value(); });
        if (stopping_) {
          return;
        }
        request = std::move(request_);
        request_.reset();
      }
      auto result = service_.observe(*request);
      {
        const std::lock_guard lock{mutex_};
        result_ = std::move(result);
        signal_.notify();
        result_ready_.store(true, std::memory_order_release);
      }
      if (completion_ != nullptr) {
        completion_->notify();
      }
      completed_.notify_one();
    }
  }

  Service &service_;
  CompletionSignal *completion_;
  CompletionSignal signal_;
  pthread_t thread_{};
  std::mutex mutex_;
  std::condition_variable ready_;
  std::condition_variable completed_;
  std::optional<typename Service::Request> request_;
  std::optional<typename Service::Result> result_;
  bool busy_ = false;
  std::atomic<bool> result_ready_{false};
  bool stopping_ = false;
};

}
