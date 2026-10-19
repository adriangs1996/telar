#pragma once

#include "lua_api.hpp"
#include <cstddef>
#include <exception>
#include <new>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

namespace lua {
  struct Vm {
    Vm() : state(luaL_newstate()) {
      if (!state) {
        throw std::bad_alloc{};
      }

      try {
        withState(
            [](lua_State *state) -> int {
              lua_pushcfunction(state, luaopen_jit);
              lua_pushliteral(state, LUA_JITLIBNAME);
              lua_call(state, 1, 0);

              if (!luaJIT_setmode(state, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON)) {
                return luaL_error(state, "Unable to enable the LuaJIT compiler");
              }

              return 0;
            },
            nullptr);
      } catch (...) {
        lua_close(state);
        throw;
      }
    }

    Vm(const Vm &) = delete;
    Vm &operator=(const Vm &) = delete;

    ~Vm() { lua_close(state); }

    std::string readGlobalString(const char *name) {
      struct Request {
        const char *name;
        std::string value;
        std::exception_ptr error;
      };

      Request request{.name = name};

      withState(
          [](lua_State *state) -> int {
            auto *request = static_cast<Request *>(lua_touserdata(state, 1));

            lua_getglobal(state, request->name);
            if (lua_type(state, -1) != LUA_TSTRING) {
              return luaL_error(state, "Global '%s' must be a string", request->name);
            }

            std::size_t length = 0;
            const char *value = lua_tolstring(state, -1, &length);

            try {
              request->value.assign(value, length);
            } catch (...) {
              request->error = std::current_exception();
            }

            return 0;
          },
          &request);

      if (request.error) {
        std::rethrow_exception(request.error);
      }

      return std::move(request.value);
    }

    void checkStatus(int status) {
      if (status != 0) {
        const auto message = lua_type(state, -1) == LUA_TSTRING
                                 ? lua_tostring(state, -1)
                                 : "Lua failed without a string error message";
        throw std::runtime_error(message);
      }
    }

    void execute(std::string_view source) {
      StackRestore restore{state, lua_gettop(state)};

      checkStatus(luaL_loadbufferx(state, source.data(), source.size(), "@telar", "t"));
      checkStatus(lua_pcall(state, 0, 0, 0));
    }

    void withState(lua_CFunction function, void *context) {
      StackRestore restore{state, lua_gettop(state)};
      checkStatus(lua_cpcall(state, function, context));
    }

  private:
    lua_State *state;

    struct StackRestore {
      lua_State *state;
      int top;

      ~StackRestore() { lua_settop(state, top); }
    };
  };
}; // namespace lua
