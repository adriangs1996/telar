#include "lua_environment.hpp"
#include "lua_vm.hpp"
#include <cstdio>
#include <cstring>
#include <string>

namespace lua {
  // A rooted coroutine shares the VM and JIT, but owns globals and library tables.
  Environment::Environment(Vm &vm)
      : vm_(vm) {
    struct Request {
      lua_State *state = nullptr;
      int reference = LUA_NOREF;
    } request;

    try {
      vm_.withState(
          [](lua_State *state) -> int {
            auto *request = static_cast<Request *>(lua_touserdata(state, 1));
            request->state = lua_newthread(state);
            request->reference = luaL_ref(state, LUA_REGISTRYINDEX);
            lua_newtable(state);
            lua_pushnil(state);

            while (lua_next(state, LUA_GLOBALSINDEX)) {
              if (lua_type(state, -2) != LUA_TSTRING) {
                lua_pop(state, 1);
                continue;
              }

              const auto *name = lua_tostring(state, -2);

              if (std::strcmp(name, "_G") != 0) {
                if (lua_istable(state, -1)) {
                  lua_newtable(state);
                  lua_pushnil(state);

                  while (lua_next(state, 4)) {
                    lua_pushvalue(state, -2);
                    lua_pushvalue(state, -2);
                    lua_rawset(state, 5);
                    lua_pop(state, 1);
                  }

                  lua_setfield(state, 2, name);
                } else {
                  lua_pushvalue(state, -1);
                  lua_setfield(state, 2, name);
                }
              }

              lua_pop(state, 1);
            }

            lua_pushvalue(state, 2);
            lua_setfield(state, 2, "_G");
            lua_xmove(state, request->state, 1);
            lua_replace(request->state, LUA_GLOBALSINDEX);
            return 0;
          },
          &request);
    } catch (...) {
      releaseReference(request.reference);
      throw;
    }

    state_ = request.state;
    reference_ = request.reference;
  }

  Environment::~Environment() {
    releaseReference(reference_);
  }

  void Environment::execute(std::string_view source, std::string_view chunk_name) {
    const std::string name(chunk_name);

    struct Request {
      std::string_view source;
      const char *name;
    } request{source, name.c_str()};

    withState(
        [](lua_State *state) -> int {
          auto *request = static_cast<Request *>(lua_touserdata(state, 1));
          lua_pushcfunction(state, traceback);

          if (luaL_loadbufferx(state,
                               request->source.data(),
                               request->source.size(),
                               request->name,
                               "t")) {
            return lua_error(state);
          }

          if (lua_pcall(state, 0, 0, 2)) {
            return lua_error(state);
          }

          return 0;
        },
        &request);
  }

  void Environment::withState(lua_CFunction function, void *context) {
    Vm::StackRestore restore{state_, lua_gettop(state_)};
    Vm::checkStatus(state_, lua_cpcall(state_, function, context));
  }

  int Environment::traceback(lua_State *state) {
    const auto *message = lua_type(state, 1) == LUA_TSTRING
                              ? lua_tostring(state, 1)
                              : "Lua failed without a string error message";
    luaL_traceback(state, state, message, 1);
    return 1;
  }

  void Environment::releaseReference(int reference) noexcept {
    if (reference == LUA_NOREF || reference == LUA_REFNIL) {
      return;
    }

    try {
      vm_.withState(
          [](lua_State *state) -> int {
            auto *reference = static_cast<int *>(lua_touserdata(state, 1));
            luaL_unref(state, LUA_REGISTRYINDEX, *reference);
            return 0;
          },
          &reference);
    } catch (...) {
      std::fputs("Unable to release a Lua registry reference\n", stderr);
    }
  }
} // namespace lua
