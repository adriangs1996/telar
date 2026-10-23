#pragma once

#include <QRectF>
#include <cstdint>
#include <memory>
#include <vector>

// Watches applications' windows through Accessibility on a thread of its own, with its own run
// loop, and records when each notification arrives.
namespace window_observer_probe {
  enum class Kind {
    created,
    destroyed,
    moved,
    resized,
    focused
  };

  struct Event {
    Kind kind;
    std::int64_t pid;
    std::uint32_t window;
    // CLOCK_UPTIME_RAW, comparable across processes.
    std::uint64_t at;
  };

  struct Attachment {
    std::int64_t pid;
    double milliseconds;
    bool answered;
  };

  class Observer final {
  public:
    // Each Accessibility call made while attaching waits at most this long for an application.
    explicit Observer(double timeout);
    ~Observer();
    Observer(const Observer &) = delete;
    Observer &operator=(const Observer &) = delete;

    // Attaches to the applications on the observer's thread and waits until it is done.
    std::vector<Attachment> attach(const std::vector<std::int64_t> &pids);
    std::vector<Event> take();

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };

  // Every running application with a Dock icon.
  std::vector<std::int64_t> regularApplications();
  std::uint64_t now();
  // The window's frame as the window server holds it, without asking its application.
  QRectF serverBounds(std::uint32_t window);
} // namespace window_observer_probe
