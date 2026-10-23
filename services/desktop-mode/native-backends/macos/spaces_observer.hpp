#pragma once

#include "desktop_state.hpp"
#include <QObject>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace macos::spaces {
  // Reads the displays and macOS's own Spaces on a thread of its own, and runs the commands that
  // wait on WindowManager or another application, such as making a layer, which can take longer
  // than a frame. Only posted commands that keep no state on the UI thread run here; everything
  // that acts on a snapshot stays on the UI thread.
  class Observer final {
  public:
    // On the UI thread: a snapshot, or the error that prevented one.
    using Delivery = std::function<void(DesktopState state, std::string error)>;

    // Deliveries run on the thread `receiver` belongs to, which must outlive the observer.
    Observer(QObject &receiver, Delivery deliver);
    ~Observer();
    Observer(const Observer &) = delete;
    Observer &operator=(const Observer &) = delete;

    void start();
    void stop();
    // While urgent, a snapshot is taken and delivered every frame, changed or not, so pending
    // operations can be confirmed or time out. Otherwise only changes are delivered.
    void setUrgent(bool urgent);
    // Takes a snapshot now, for a change macOS announced or a command just sent.
    void wake();
    // Runs a task on the observer's thread right before its next snapshot, which is delivered
    // whether it changed or not, carrying the task's error if it threw. For commands that wait
    // on another application or the window server and leave no state behind on the UI thread.
    void post(std::function<void()> task);

  private:
    QObject &receiver_;
    Delivery deliver_;
    std::mutex mutex_;
    std::condition_variable_any woken_;
    bool wake_ = false;
    std::vector<std::function<void()>> tasks_;
    std::atomic<bool> urgent_ = false;
    std::jthread thread_;

    void run(std::stop_token stop);
  };
} // namespace macos::spaces
