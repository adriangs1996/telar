#include "timer_binding.hpp"
#include "../trace.hpp"
#include <QDebug>
#include <memory>
#include <stdexcept>

namespace {
  constexpr std::size_t timer_limit = 256;
} // namespace

namespace ui {
  TimerBinding::TimerBinding(lua::Environment &environment)
      : environment_(environment) {}

  TimerBinding::~TimerBinding() {
    for (const auto &[id, timer] : timers_) {
      environment_.releaseReference(timer.reference);
    }
  }

  void TimerBinding::activate() {
    active_ = true;

    for (const auto &[id, timer] : timers_) {
      timer.timer->start();
    }
  }

  void TimerBinding::deactivate() {
    active_ = false;

    for (const auto &[id, timer] : timers_) {
      timer.timer->stop();
    }
  }

  std::uint64_t TimerBinding::start(int reference, int delay_ms) {
    if (timers_.size() >= timer_limit) {
      throw std::runtime_error("UI timer limit reached");
    }

    const auto id = next_id_++;
    auto timer = std::make_unique<QTimer>();
    timer->setSingleShot(true);
    timer->setInterval(delay_ms);
    QObject::connect(timer.get(), &QTimer::timeout, timer.get(), [this, id] {
      fire(id);
    });

    if (active_) {
      timer->start();
    }

    timers_.emplace(id, Timer{reference, std::move(timer)});
    return id;
  }

  void TimerBinding::cancel(std::uint64_t identifier) {
    const auto found = timers_.find(identifier);

    if (found != timers_.end()) {
      environment_.releaseReference(found->second.reference);
      timers_.erase(found);
    }
  }

  // The timer leaves the map before its callback runs, so the callback may start new timers and
  // a late cancel of this one does nothing.
  void TimerBinding::fire(std::uint64_t identifier) {
    TELAR_TRACE("lua.timer.fire");
    auto found = timers_.find(identifier);

    if (found == timers_.end() || !active_) {
      return;
    }

    int reference = found->second.reference;
    auto timer = std::move(found->second.timer);
    timers_.erase(found);
    timer.release()->deleteLater();

    try {
      environment_.withState(
          [](lua_State *state) -> int {
            const auto reference = *static_cast<int *>(lua_touserdata(state, 1));
            lua_pushcfunction(state, lua::Environment::traceback);
            lua_rawgeti(state, LUA_REGISTRYINDEX, reference);

            if (lua_pcall(state, 0, 0, 2) != 0) {
              return lua_error(state);
            }

            return 0;
          },
          &reference);
    } catch (const std::exception &error) {
      qWarning() << "Lua timer callback failed:" << error.what();
    }

    environment_.releaseReference(reference);
  }
} // namespace ui
