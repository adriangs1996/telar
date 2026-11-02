#pragma once

#include "../memory/fixed_text.hpp"
#include "../text/identifier.hpp"
#include "vm.hpp"
#include <cstdio>
#include <limits.h>
#include <sys/stat.h>

namespace telar::runtime::lua {

enum class ModuleDomain {
  configuration,
  package
};

template <ModuleDomain domain>
class LocalModules {
public:
  explicit LocalModules(lua_State *state, std::string_view directory) {
    directory_.assign(directory);
    lua_createtable(state, 0, domain == ModuleDomain::configuration ? module_limit : 16);
    cache_ = luaL_ref(state, LUA_REGISTRYINDEX);
    lua_pushlightuserdata(state, this);
    lua_pushcclosure(state, &require, 1);
    lua_setglobal(state, "require");
  }

  LocalModules(const LocalModules &) = delete;
  LocalModules &operator=(const LocalModules &) = delete;

  [[nodiscard]] std::size_t configurationModuleCount() const noexcept requires(domain == ModuleDomain::configuration) {
    return static_cast<std::size_t>(loaded_);
  }

  template <typename Visitor>
  void visitLoadedNames(lua_State *state, Visitor &&visit) const {
    constexpr int traversal_slots = 3;
    if (lua_checkstack(state, traversal_slots) == 0) {
      throw Error{"Cannot inspect local module dependencies"};
    }

    const auto initial_top = lua_gettop(state);
    lua_rawgeti(state, LUA_REGISTRYINDEX, cache_);
    lua_pushnil(state);
    try {
      while (lua_next(state, -2) != 0) {
        std::size_t length = 0;
        const auto *name = lua_tolstring(state, -2, &length);
        visit(std::string_view{name, length});
        lua_pop(state, 1);
      }
    } catch (...) {
      lua_settop(state, initial_top);
      throw;
    }

    lua_settop(state, initial_top);
  }

private:
  static int raise(lua_State *state, const char *configuration, const char *package) {
    lua_pushstring(state, domain == ModuleDomain::configuration ? configuration : package);
    return lua_error(state);
  }

  static int require(lua_State *state) {
    auto &modules = *static_cast<LocalModules *>(lua_touserdata(state, lua_upvalueindex(1)));
    if (domain == ModuleDomain::configuration && lua_type(state, 1) != LUA_TSTRING) {
      return luaL_error(state, "require expects a module name");
    }

    std::size_t size = 0;
    const auto *bytes = lua_tolstring(state, 1, &size);
    if (bytes == nullptr) {
      return luaL_error(state, "require expects a module name");
    }

    const std::string_view name{bytes, size};
    if (name == "telar") {
      lua_getglobal(state, "telar");
      return 1;
    }
    if (domain == ModuleDomain::package && name == "telar.traffic") {
      lua_getglobal(state, "telar");
      lua_getfield(state, -1, "traffic");
      if (lua_isnil(state, -1)) { return luaL_error(state, "Traffic API is unavailable"); }
      return 1;
    }
    if (!validIdentifier(name)) {
      return raise(state, "Invalid local module name", "invalid local module name");
    }

    lua_rawgeti(state, LUA_REGISTRYINDEX, modules.cache_);
    lua_pushvalue(state, 1);
    lua_rawget(state, -2);
    if (!lua_isnil(state, -1)) {
      return 1;
    }
    lua_pop(state, 1);

    const auto directory = modules.directory_.view();
    std::array<char, PATH_MAX> path;
    if (directory.size() + name.size() + sizeof("/.lua") > path.size()) {
      return raise(state, "Local module path is too long", "module path too long");
    }

    std::memcpy(path.data(), directory.data(), directory.size());
    path[directory.size()] = '/';
    auto *suffix = path.data() + directory.size() + 1;
    std::transform(name.begin(), name.end(), suffix, [](char byte) { return byte == '.' ? '/' : byte; });
    std::memcpy(suffix + name.size(), ".lua", sizeof(".lua"));
    std::array<char, PATH_MAX> canonical;
    if (::realpath(path.data(), canonical.data()) == nullptr) {
      return raise(state, "Cannot resolve local configuration module", "cannot resolve local module");
    }

    const std::string_view resolved{canonical.data()};
    if (!resolved.starts_with(directory) || (resolved.size() != directory.size() && resolved[directory.size()] != '/')) {
      return raise(state, "Local configuration module escapes the configuration directory", "module escapes package");
    }
    struct stat metadata{};
    if (::stat(canonical.data(), &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
      return luaL_error(state, "Local configuration module must be a regular file");
    }
    if (luaL_loadfilex(state, canonical.data(), "t") != LUA_OK || lua_pcall(state, 0, 1, 0) != LUA_OK) {
      return lua_error(state);
    }
    if (lua_isnil(state, -1)) {
      lua_pop(state, 1);
      lua_pushboolean(state, true);
    }
    if (domain == ModuleDomain::configuration && modules.loaded_ == module_limit) {
      return luaL_error(state, "Configuration requires too many local modules");
    }

    if constexpr (domain == ModuleDomain::configuration) {
      ++modules.loaded_;
    }
    lua_pushvalue(state, 1);
    lua_pushvalue(state, -2);
    lua_rawset(state, -4);
    return 1;
  }

  static constexpr int module_limit = 64;
  FixedText<PATH_MAX> directory_;
  int cache_ = LUA_NOREF;
  int loaded_ = 0;
};

}
