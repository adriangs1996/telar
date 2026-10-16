module;
#include "lua_api.hpp"
#include <new>
#include <stdexcept>
#include <string_view>
export module lua_vm;

export namespace lua {
  struct Vm {
    Vm() : state(luaL_newstate()) {
      if (!state) {
        throw std::bad_alloc{};
      }
    }

    Vm(const Vm &) = delete;
    Vm &operator=(const Vm &) = delete;

    ~Vm() { lua_close(state); }

    void execute(std::string_view source) {
      struct StackRestore {
        lua_State *state;
        int top;

        ~StackRestore() { lua_settop(state, top); }
      };

      StackRestore restore{state, lua_gettop(state)};

      if (luaL_loadbufferx(state, source.data(), source.size(), "@telar", "t") != 0 ||
          lua_pcall(state, 0, 0, 0) != 0) {
        const auto message = lua_type(state, -1) == LUA_TSTRING
                                 ? lua_tostring(state, -1)
                                 : "Lua failed without a string error message";

        throw std::runtime_error(message);
      }
    }

  private:
    lua_State *state;
  };
}; // namespace lua
