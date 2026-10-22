#include "module_watch.hpp"
#include "../trace.hpp"
#include <QDir>
#include <utility>
#include <vector>

namespace ui {
  ModuleWatch::ModuleWatch() {
    watch_.setCallback([this](const QStringList &paths) {
      notify(paths);
    });
  }

  std::uint64_t ModuleWatch::subscribe(std::function<void()> changed) {
    const auto subscription = next_++;
    subscribers_.emplace(subscription, Subscriber{{}, std::move(changed)});
    return subscription;
  }

  void ModuleWatch::unsubscribe(std::uint64_t subscription) {
    if (subscribers_.erase(subscription)) {
      rearm();
    }
  }

  void ModuleWatch::setPaths(std::uint64_t subscription, const QStringList &paths) {
    TELAR_TRACE("ui.module_watch.set_paths");
    const auto found = subscribers_.find(subscription);
    if (found == subscribers_.end()) {
      return;
    }

    // The file watch reports cleaned paths, so subscribers keep them cleaned too.
    QSet<QString> cleaned;
    for (const auto &path : paths) {
      cleaned.insert(QDir::cleanPath(path));
    }

    if (found->second.paths != cleaned) {
      found->second.paths = std::move(cleaned);
      rearm();
    }
  }

  void ModuleWatch::rearm() {
    QSet<QString> watched;
    for (const auto &[subscription, subscriber] : subscribers_) {
      watched.unite(subscriber.paths);
    }

    if (watched != watched_) {
      watched_ = std::move(watched);
      watch_.setPaths(watched_.values());
    }
  }

  void ModuleWatch::notify(const QStringList &paths) {
    TELAR_TRACE("ui.module_watch.notify");
    // A callback can subscribe, unsubscribe or change paths: run a copy of the affected ones.
    std::vector<std::function<void()>> affected;
    for (const auto &[subscription, subscriber] : subscribers_) {
      for (const auto &path : paths) {
        if (subscriber.paths.contains(path)) {
          affected.push_back(subscriber.changed);
          break;
        }
      }
    }

    for (const auto &changed : affected) {
      if (changed) {
        changed();
      }
    }
  }
} // namespace ui
