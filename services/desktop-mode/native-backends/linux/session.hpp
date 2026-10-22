#pragma once

#include "compositor.h"
#include "../../shortcuts.hpp"
#include "../../ui/workbench/native.hpp"
#include <QObject>
#include <QSocketNotifier>
#include <atomic>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

namespace linux_desktop {
  struct Output {
    std::uint32_t id;
    QString name;
    QRect geometry;
    QRect available;
    double scale;
    std::uint64_t space;
    bool operator==(const Output &) const = default;
  };

  struct Surface {
    std::uint32_t resource;
    QRect geometry;
    bool operator==(const Surface &) const = default;
  };

  struct Snapshot {
    std::vector<Output> outputs;
    std::vector<Surface> surfaces;
    workbench::native::ForeignWindows windows;
    std::uint64_t focused_space = 0;
    bool operator==(const Snapshot &) const = default;
  };

  // Qt is a client of this server. Only the worker touches wlroots; eventfd queues
  // cross the boundary without a synchronous call into Qt's Wayland connection.
  class Session final {
  public:
    Session();
    ~Session();
    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;
    static Session &get();
    void attach();
    void post(std::function<void(telar_server *)> command);
    std::uint64_t subscribe(std::function<void(const Snapshot &)> callback);
    void unsubscribe(std::uint64_t subscription);
    const Snapshot &snapshot() const;
    void capture(Shortcuts::Capture capture);
    std::function<void(Shortcuts::Request)> shortcut;
    std::function<void()> lockRequest;

  private:
    static Session *current_;
    int commands_fd_ = -1;
    int updates_fd_ = -1;
    std::thread thread_;
    std::atomic<bool> stopping_ = false;
    std::atomic<bool> lock_requested_ = false;
    std::mutex mutex_;
    std::deque<std::function<void(telar_server *)>> commands_;
    std::vector<Shortcuts::Request> requests_;
    std::unique_ptr<Snapshot> pending_;
    Snapshot snapshot_;
    std::map<std::uint64_t, std::function<void(const Snapshot &)>> subscribers_;
    std::uint64_t next_subscription_ = 0;
    std::unique_ptr<QSocketNotifier> notifier_;
    // Worker-only state.
    telar_server *server_ = nullptr;
    keybindings::Router router_;
    std::uint64_t epoch_ = 0;
    void drain();
    void publish();
    void deliver();
    bool key(const telar_key_event &event);
  };

  telar_target target(QWindow &window);
  void place(QWindow &window, std::uint64_t space, telar_layer layer, bool focusable);
  void focus(QWindow &window);
} // namespace linux_desktop
