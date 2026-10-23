#pragma once

#include "../lua_environment.hpp"
#include <QObject>
#include <QTimer>
#include <cstdint>
#include <map>
#include <memory>

namespace ui {
  // One-shot timers for a Lua generation. A timer started before the generation is active waits
  // for activation, and a deactivated generation stops every timer it holds.
  class TimerBinding final {
  public:
    static constexpr int maximum_delay_ms = 24 * 60 * 60 * 1000;

    explicit TimerBinding(lua::Environment &environment);
    ~TimerBinding();
    void activate();
    void deactivate();
    std::uint64_t start(int reference, int delay_ms);
    void cancel(std::uint64_t identifier);

  private:
    struct Timer {
      int reference;
      std::unique_ptr<QTimer> timer;
    };

    lua::Environment &environment_;
    std::map<std::uint64_t, Timer> timers_;
    std::uint64_t next_id_ = 1;
    bool active_ = false;
    void fire(std::uint64_t identifier);
  };
} // namespace ui
