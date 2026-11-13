#pragma once

#include <QMetaObject>
#include <QObject>
#include <QString>
#include <QThread>

#include <exception>
#include <memory>
#include <optional>
#include <type_traits>
#include <utility>

namespace telar::gui::qt {

template <typename Value>
struct LuaOutcome {
  std::optional<Value> value;
  QString error;
  // The configuration that ran the call was replaced before its result arrived.
  bool stale = false;
};

template <>
struct LuaOutcome<void> {
  bool done = false;
  QString error;
  bool stale = false;
};

// Runs every call into one client VM on a single thread, in submission order, so a slow
// or runaway Lua function delays other Lua work instead of the window.
class LuaHost final : public QObject {
public:
  explicit LuaHost(QObject *parent = nullptr);
  ~LuaHost() override;
  LuaHost(const LuaHost &) = delete;
  LuaHost &operator=(const LuaHost &) = delete;
  LuaHost(LuaHost &&) = delete;
  LuaHost &operator=(LuaHost &&) = delete;

  // `work` runs on the Lua thread; `done` runs on this object's thread with its outcome.
  template <typename Work, typename Done>
  void post(Work work, Done done) {
    using Value = std::invoke_result_t<Work &>;
    struct Task {
      Work work;
      Done done;
      LuaOutcome<Value> outcome;
    };
    auto task = std::make_shared<Task>(Task{.work = std::move(work), .done = std::move(done), .outcome = {}});
    ++pending_;
    QMetaObject::invokeMethod(worker_, [this, task] {
      try {
        if constexpr (std::is_void_v<Value>) {
          task->work();
          task->outcome.done = true;
        } else {
          task->outcome.value.emplace(task->work());
        }
      } catch (const std::exception &error) {
        task->outcome.error = QString::fromUtf8(error.what());
      }

      // The window thread owns `this`; its destructor waits for this thread first.
      QMetaObject::invokeMethod(this, [this, task] {
        --pending_;
        task->done(std::move(task->outcome));
      }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
  }

  [[nodiscard]] bool idle() const noexcept {
    return pending_ == 0;
  }

private:
  QThread thread_;
  QObject *worker_ = nullptr;
  std::size_t pending_ = 0;
};

}
