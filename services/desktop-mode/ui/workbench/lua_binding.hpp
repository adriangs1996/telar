#pragma once

#include "../../lua_environment.hpp"
#include <map>
#include <QObject>

namespace ui {
  struct Services;
}

namespace workbench {
  class LuaBinding final {
  public:
    LuaBinding(lua::Environment &environment, ui::Services &services);
    ~LuaBinding();
    void activate();
    void deactivate();
    std::uint64_t subscribe(int reference);
    void unsubscribe(std::uint64_t identifier);

  private:
    lua::Environment &environment_;
    ui::Services &services_;
    std::uint64_t subscription_ = 0, next_id_ = 1;
    std::map<std::uint64_t, int> callbacks_;
    bool active_ = false;
    QObject lifetime_;
    void deliver();
  };
} // namespace workbench
