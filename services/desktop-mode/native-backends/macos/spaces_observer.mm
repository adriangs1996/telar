#include "spaces_observer.hpp"
#include "spaces_bridge.hpp"
#include "../../trace.hpp"
#import <Foundation/Foundation.h>
#include <QMetaObject>
#include <QThread>
#include <chrono>
#include <exception>
#include <utility>

namespace macos::spaces {
  namespace {
    using namespace std::chrono_literals;
    constexpr auto frame_interval = 16ms;
    constexpr auto idle_interval = 2s;
  } // namespace

  Observer::Observer(QObject &receiver, Delivery deliver)
      : receiver_(receiver),
        deliver_(std::move(deliver)) {}

  Observer::~Observer() {
    stop();
  }

  void Observer::start() {
    if (!thread_.joinable()) {
      thread_ = std::jthread([this](std::stop_token stop) {
        run(stop);
      });
    }
  }

  void Observer::stop() {
    if (thread_.joinable()) {
      thread_.request_stop();
      thread_.join();
    }
  }

  void Observer::setUrgent(bool urgent) {
    if (urgent_.exchange(urgent) != urgent && urgent) {
      wake();
    }
  }

  void Observer::wake() {
    {
      std::lock_guard lock(mutex_);
      wake_ = true;
    }

    woken_.notify_one();
  }

  void Observer::post(std::function<void()> task) {
    {
      std::lock_guard lock(mutex_);
      tasks_.push_back(std::move(task));
      wake_ = true;
    }

    woken_.notify_one();
  }

  void Observer::run(std::stop_token stop) {
    QThread::currentThread()->setObjectName(QStringLiteral("spaces"));
    DesktopState delivered;
    std::string delivered_error;
    bool first = true;

    while (!stop.stop_requested()) {
      std::vector<std::function<void()>> tasks;
      {
        std::unique_lock lock(mutex_);
        woken_.wait_for(lock, stop, urgent_ ? frame_interval : idle_interval, [this] {
          return wake_;
        });

        wake_ = false;
        std::swap(tasks, tasks_);
      }

      if (stop.stop_requested()) {
        break;
      }

      std::string error;
      for (const auto &task : tasks) {
        @autoreleasepool {
          try {
            task();
          } catch (const std::exception &failure) {
            error = failure.what();
          }
        }
      }

      DesktopState state;
      @autoreleasepool {
        try {
          state = snapshot();
        } catch (const std::exception &failure) {
          if (error.empty()) {
            error = failure.what();
          }
        }
      }

      if (!first && !urgent_ && tasks.empty() && state == delivered && error == delivered_error) {
        continue;
      }

      first = false;
      delivered = state;
      delivered_error = error;
      QMetaObject::invokeMethod(
          &receiver_,
          [deliver = deliver_, state = std::move(state), error = std::move(error)]() mutable {
            deliver(std::move(state), std::move(error));
          },
          Qt::QueuedConnection);
    }
  }
} // namespace macos::spaces
