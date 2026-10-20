#pragma once

#include "lua_api.hpp"
#include <string_view>

namespace lua {
  struct Vm;

  struct Environment final {
    explicit Environment(Vm &vm);
    ~Environment();

    Environment(const Environment &) = delete;
    Environment &operator=(const Environment &) = delete;

    void execute(std::string_view source, std::string_view chunk_name);
    void withState(lua_CFunction function, void *context);
    void releaseReference(int reference) noexcept;
    static int traceback(lua_State *state);

  private:
    Vm &vm_;
    lua_State *state_ = nullptr;
    int reference_ = LUA_NOREF;
  };
} // namespace lua
