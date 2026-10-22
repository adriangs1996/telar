#include "lua_binding.hpp"
#include "controller.hpp"
#include "../services.hpp"
#include "../../trace.hpp"
#include <QDebug>
#include <QTimer>
#include <stdexcept>
#include <utility>

namespace workbench {
  LuaBinding::LuaBinding(lua::Environment &environment, ui::Services &services)
      : environment_(environment),
        services_(services) {}

  LuaBinding::~LuaBinding() {
    deactivate();
    for (const auto &[id, reference] : callbacks_) {
      environment_.releaseReference(reference);
    }
  }

  void LuaBinding::activate() {
    TELAR_TRACE("lua.workbench.activate");
    active_ = true;
    if (services_.workbench) {
      subscription_ = services_.workbench->subscribe([this] {
        deliver();
      });
    } else {
      QTimer::singleShot(0, &lifetime_, [this] {
        if (active_ && !subscription_ && services_.workbench) {
          subscription_ = services_.workbench->subscribe([this] {
            deliver();
          });
        }
      });
    }
  }

  void LuaBinding::deactivate() {
    TELAR_TRACE("lua.workbench.deactivate");
    active_ = false;
    if (services_.workbench && subscription_) {
      services_.workbench->unsubscribe(subscription_);
    }

    subscription_ = 0;
  }

  std::uint64_t LuaBinding::subscribe(int reference) {
    constexpr std::size_t subscription_limit = 128;
    if (callbacks_.size() >= subscription_limit) {
      throw std::runtime_error("Workbench subscription limit reached");
    }

    const auto id = next_id_++;
    callbacks_.emplace(id, reference);
    return id;
  }

  void LuaBinding::unsubscribe(std::uint64_t id) {
    const auto found = callbacks_.find(id);
    if (found != callbacks_.end()) {
      environment_.releaseReference(found->second);
      callbacks_.erase(found);
    }
  }

  void LuaBinding::deliver() {
    TELAR_TRACE("lua.workbench.deliver");
    if (!active_) {
      return;
    }

    const auto callbacks = callbacks_;
    for (const auto &[id, reference] : callbacks) {
      if (!callbacks_.contains(id)) {
        continue;
      }

      int argument = reference;
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
            &argument);
      } catch (const std::exception &error) {
        qWarning() << "Lua workbench callback failed:" << error.what();
      }
    }
  }
} // namespace workbench
