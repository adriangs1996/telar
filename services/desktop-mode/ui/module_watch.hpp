#pragma once

#include "file_watch.hpp"
#include <QSet>
#include <QStringList>
#include <cstdint>
#include <functional>
#include <map>

namespace ui {
  // One file watch shared by every Lua environment. Each pane has an environment of its own and
  // they all load the same modules, while every change of a watch's paths makes macOS restart its
  // event stream and rescan the watched directories. The shared watch changes only when the union
  // of the subscribers' paths does.
  class ModuleWatch final {
  public:
    ModuleWatch();
    // `changed` runs when one of the subscriber's paths changes.
    std::uint64_t subscribe(std::function<void()> changed);
    void unsubscribe(std::uint64_t subscription);
    void setPaths(std::uint64_t subscription, const QStringList &paths);

  private:
    struct Subscriber {
      QSet<QString> paths;
      std::function<void()> changed;
    };

    FileWatch watch_;
    std::map<std::uint64_t, Subscriber> subscribers_;
    QSet<QString> watched_;
    std::uint64_t next_ = 1;

    void rearm();
    void notify(const QStringList &paths);
  };
} // namespace ui
