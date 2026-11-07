module;
#include <limits>
#include <utility>
#include <concepts>
#include <cstddef>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <vector>
#include <type_traits>
#include <variant>
#include <bit>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include <array>
#include <chrono>
#include <cstring>
#include <ctime>
#include <stdexcept>
#include <string_view>

#include <exception>
#include <charconv>
#include <cstdint>
#include <optional>
#include <span>

#include <algorithm>
#include <cstdio>
#include <limits.h>
#include <sys/stat.h>

#include <cmath>
#include <initializer_list>
#include <string>

export module telar.lua;

export import telar.base.text;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;

// Interface: telar_lua/api.cppm
export {

}

// Interface: telar_lua/vm.cppm
export {
namespace telar::runtime::lua {

class Error : public std::exception {
public:
  inline explicit Error(std::string_view message) noexcept {
    const auto size = std::min(message.size(), message_.size() - 1);
    if (size != 0) {
      std::memcpy(message_.data(), message.data(), size);
    }
    message_[size] = '\0';
  }

  inline const char *what() const noexcept override {
    return message_.data();
  }

private:
  std::array<char, 1024> message_;
};

struct Limits {
  std::size_t memory = std::size_t{256} * 1024 * 1024;
  std::uint64_t instructions = 50'000'000;
  std::chrono::nanoseconds deadline = std::chrono::seconds{2};
};

template <Allocator Memory>
class Vm {
public:
  inline explicit Vm(Memory &memory, Limits limits = {})
      : memory_(memory),
        limits_(limits),
        deadline_(Clock::now() + limits.deadline) {
    state_ = lua_newstate(&allocate, this, 0);
    if (state_ == nullptr) {
      throw std::bad_alloc{};
    }

    lua_atpanic(state_, &panic);
    lua_sethook(state_, &instructionHook, LUA_MASKCOUNT, instruction_interval);
    try {
      invoke(&openSandbox, nullptr, 0);
    } catch (...) {
      lua_close(state_);
      throw;
    }
  }

  inline ~Vm() {
    lua_close(state_);
  }

  Vm(const Vm &) = delete;
  Vm &operator=(const Vm &) = delete;

  inline void resetBudget() noexcept {
    instructions_ = 0;
    deadline_ = Clock::now() + limits_.deadline;
  }

  inline void resetBudget(std::uint64_t instructions, std::chrono::nanoseconds deadline) noexcept {
    limits_.instructions = instructions;
    limits_.deadline = deadline;
    resetBudget();
  }

  inline void execute(std::string_view source, const char *name, int results = 1) {
    check(luaL_loadbufferx(state_, source.data(), source.size(), name, "t"));
    check(lua_pcall(state_, 0, results, 0));
  }

  inline void invoke(lua_CFunction function, void *context, int results) {
    lua_pushcfunction(state_, function);
    lua_pushlightuserdata(state_, context);
    check(lua_pcall(state_, 1, results, 0));
  }

  inline lua_State *state() const noexcept {
    return state_;
  }

  inline std::size_t usedBytes() const noexcept {
    return used_bytes_;
  }

private:
  using Clock = std::chrono::steady_clock;
  static constexpr int instruction_interval = 1000;

  struct alignas(std::max_align_t) Allocation {
    std::size_t capacity;
  };

  inline static Vm &owner(lua_State *state) noexcept {
    void *context = nullptr;
    lua_getallocf(state, &context);
    return *static_cast<Vm *>(context);
  }

  inline static void *allocate(void *context, void *pointer, std::size_t old_size, std::size_t new_size) noexcept {
    auto &vm = *static_cast<Vm *>(context);
    const auto previous = pointer == nullptr ? 0 : old_size;
    const auto retained = vm.used_bytes_ - previous;
    if (new_size == 0) {
      vm.release(pointer);
      vm.used_bytes_ = retained;
      return nullptr;
    }
    if (new_size > vm.limits_.memory - retained || new_size > std::numeric_limits<std::size_t>::max() - sizeof(Allocation)) {
      return nullptr;
    }

    if (pointer != nullptr && new_size <= previous) {
      vm.used_bytes_ = retained + new_size;
      return pointer;
    }

    auto *allocation = static_cast<Allocation *>(vm.memory_.allocate(sizeof(Allocation) + new_size, alignof(Allocation)));
    if (allocation == nullptr) {
      return nullptr;
    }

    allocation->capacity = new_size;
    if (pointer != nullptr) {
      std::memcpy(allocation + 1, pointer, previous);
      vm.release(pointer);
    }

    vm.used_bytes_ = retained + new_size;
    return allocation + 1;
  }

  inline void release(void *pointer) noexcept {
    if (pointer != nullptr) {
      auto *allocation = static_cast<Allocation *>(pointer) - 1;
      memory_.deallocate(allocation, sizeof(Allocation) + allocation->capacity, alignof(Allocation));
    }
  }

  inline static void instructionHook(lua_State *state, lua_Debug *) {
    auto &vm = owner(state);
    vm.instructions_ += instruction_interval;
    if (vm.instructions_ > vm.limits_.instructions || Clock::now() > vm.deadline_) {
      luaL_error(state, "Telar Lua execution budget exceeded");
    }
  }

  inline static int panic(lua_State *state) {
    std::size_t size = 0;
    const auto *message = lua_tolstring(state, -1, &size);
    throw Error{message == nullptr ? std::string_view{"Unprotected Lua failure"} : std::string_view{message, size}};
  }

  inline void check(int status) {
    if (status == LUA_OK) {
      return;
    }
    if (status == LUA_ERRMEM) {
      throw std::bad_alloc{};
    }

    panic(state_);
  }

  inline static int openSandbox(lua_State *state) {
    constexpr std::array libraries{
        luaL_Reg{"_G", luaopen_base},
        luaL_Reg{LUA_COLIBNAME, luaopen_coroutine},
        luaL_Reg{LUA_MATHLIBNAME, luaopen_math},
        luaL_Reg{LUA_STRLIBNAME, luaopen_string},
        luaL_Reg{LUA_TABLIBNAME, luaopen_table},
        luaL_Reg{LUA_UTF8LIBNAME, luaopen_utf8},
    };
    for (const auto &library : libraries) {
      luaL_requiref(state, library.name, library.func, 1);
      lua_pop(state, 1);
    }

    for (const auto *name : {"collectgarbage", "dofile", "getmetatable", "load", "loadfile", "print", "rawset", "setmetatable"}) {
      lua_pushnil(state);
      lua_setglobal(state, name);
    }

    // Only the clock: the standard os library also spawns processes and reads the environment.
    constexpr std::array clock{
        luaL_Reg{"time", &osTime},
        luaL_Reg{"clock", &osClock},
        luaL_Reg{"date", &osDate},
    };
    lua_createtable(state, 0, static_cast<int>(clock.size()));
    for (const auto &function : clock) {
      lua_pushcfunction(state, function.func);
      lua_setfield(state, -2, function.name);
    }

    lua_setglobal(state, "os");

    return 0;
  }

  inline static int osTime(lua_State *state) {
    if (!lua_isnoneornil(state, 1)) {
      return luaL_error(state, "os.time accepts no arguments");
    }

    lua_pushinteger(state, static_cast<lua_Integer>(std::time(nullptr)));

    return 1;
  }

  inline static int osClock(lua_State *state) {
    lua_pushnumber(state, static_cast<lua_Number>(std::clock()) / static_cast<lua_Number>(CLOCKS_PER_SEC));

    return 1;
  }

  inline static int osDate(lua_State *state) {
    constexpr std::string_view allowed{"aAbBcdDeFHIjmMnpRSTuUVwWxXyYzZ%"};
    constexpr std::size_t maximum_format_bytes = 64;
    constexpr std::size_t maximum_output_bytes = 256;
    std::size_t size = 0;
    const char *bytes = luaL_optlstring(state, 1, "%c", &size);
    std::string_view format{bytes, size};
    const auto when = static_cast<std::time_t>(luaL_optinteger(state, 2, static_cast<lua_Integer>(std::time(nullptr))));
    const bool utc = format.starts_with('!');
    if (utc) {
      format.remove_prefix(1);
    }

    if (format.size() > maximum_format_bytes) {
      return luaL_error(state, "os.date format exceeds 64 bytes");
    }

    for (std::size_t index = 0; index < format.size(); ++index) {
      if (format[index] == '%' && (++index == format.size() || !allowed.contains(format[index]))) {
        return luaL_error(state, "os.date format uses an unsupported conversion");
      }
    }

    std::tm calendar{};
    if ((utc ? ::gmtime_r(&when, &calendar) : ::localtime_r(&when, &calendar)) == nullptr) {
      return luaL_error(state, "os.date time is out of range");
    }

    std::array<char, maximum_format_bytes + 1> pattern{};
    std::ranges::copy(format, pattern.begin());
    std::array<char, maximum_output_bytes> output{};
    const auto written = format.empty() ? 0 : std::strftime(output.data(), output.size(), pattern.data(), &calendar);
    lua_pushlstring(state, output.data(), written);

    return 1;
  }

  Memory &memory_;
  Limits limits_;
  Clock::time_point deadline_;
  std::uint64_t instructions_ = 0;
  std::size_t used_bytes_ = 0;
  lua_State *state_ = nullptr;
};

template <Allocator Memory>
Vm(Memory &memory, Limits limits = {}) -> Vm<Memory>;

}
}

// Interface: telar_lua/json.cppm
export {
namespace telar::runtime::lua {

template <Allocator Memory>
class JsonDecoder {
public:
  inline static void install(lua_State *state, Memory &memory) {
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, &memory);
    lua_pushcclosure(state, &decode, 1);
    lua_setfield(state, -2, "decode");
    lua_setfield(state, -2, "json");
  }

private:
  inline explicit JsonDecoder(Memory &memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  inline static int decode(lua_State *state) {
    if (lua_type(state, 1) != LUA_TSTRING) {
      return luaL_error(state, "json.decode expects a string");
    }

    std::size_t size = 0;
    const auto *bytes = lua_tolstring(state, 1, &size);
    if (size > maximum_input_bytes) {
      return luaL_error(state, "JSON input is too large");
    }

    try {
      const std::string_view input{bytes, size};
      validateUtf8(input);
      const auto document = JsonValue::parse(input, maximum_depth - 1);
      auto &memory = *static_cast<Memory *>(lua_touserdata(state, lua_upvalueindex(1)));
      JsonDecoder decoder{memory};
      decoder.push(state, document, 0);
      return 1;
    } catch (const std::exception &error) {
      return luaL_error(state, "%s", error.what());
    }
  }

  inline void push(lua_State *state, const JsonValue &value, unsigned depth) {
    if (depth == maximum_depth || !lua_checkstack(state, 6)) {
      throw Error{"JSON exceeds the depth limit"};
    }

    switch (value.encoded().front()) {
    case 'n':
      lua_pushnil(state);
      break;
    case 't':
    case 'f':
      lua_pushboolean(state, value.boolean());
      break;
    case '"':
      value.string(text_);
      lua_pushlstring(state, text_.data(), text_.size());
      break;
    case '[': {
      int count = 0;
      value.eachElement([&](const JsonValue &) { ++count; });
      lua_createtable(state, count, 0);
      const auto table = lua_absindex(state, -1);
      lua_Integer index = 0;
      value.eachElement([&](const JsonValue &element) {
        push(state, element, depth + 1);
        lua_rawseti(state, table, ++index);
      });
      break;
    }
    case '{':
      object(state, value, depth);
      break;
    default:
      text_ = value.encoded();
      if (lua_stringtonumber(state, text_.c_str()) != text_.size() + 1) {
        throw Error{"JSON number is outside its bounds"};
      }
    }
  }

  inline void object(lua_State *state, const JsonValue &value, unsigned depth) {
    int count = 0;
    value.eachMember([&](const JsonValue &, const JsonValue &) { ++count; });
    lua_createtable(state, 0, count);
    const auto table = lua_absindex(state, -1);
    lua_newtable(state);
    const auto names = lua_absindex(state, -1);
    value.eachMember([&](const JsonValue &key, const JsonValue &member) {
      key.string(text_);
      lua_pushlstring(state, text_.data(), text_.size());
      lua_pushvalue(state, -1);
      lua_rawget(state, names);
      if (!lua_isnil(state, -1)) {
        throw Error{"JSON object contains a duplicate key"};
      }

      lua_pop(state, 1);
      lua_pushvalue(state, -1);
      lua_pushboolean(state, true);
      lua_rawset(state, names);
      push(state, member, depth + 1);
      lua_rawset(state, table);
    });
    lua_pop(state, 1);
  }

  static constexpr std::size_t maximum_input_bytes = 1024 * 1024;
  static constexpr unsigned maximum_depth = 64;
  String<Memory> text_;
};

}
}

// Interface: telar_lua/local_modules.cppm
export {
namespace telar::runtime::lua {

enum class ModuleDomain {
  configuration,
  package
};

template <ModuleDomain domain>
class LocalModules {
public:
  inline explicit LocalModules(lua_State *state, std::string_view directory) {
    directory_.assign(directory);
    constexpr int expected_modules = 16;
    lua_createtable(state, 0, expected_modules);
    cache_ = luaL_ref(state, LUA_REGISTRYINDEX);
    lua_pushlightuserdata(state, this);
    lua_pushcclosure(state, &require, 1);
    lua_setglobal(state, "require");
  }

  LocalModules(const LocalModules &) = delete;
  LocalModules &operator=(const LocalModules &) = delete;

  [[nodiscard]] inline std::size_t configurationModuleCount() const noexcept requires(domain == ModuleDomain::configuration) {
    return static_cast<std::size_t>(loaded_);
  }

  template <typename Visitor>
  inline void visitLoadedNames(lua_State *state, Visitor &&visit) const {
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
  inline static int raise(lua_State *state, const char *configuration, const char *package) {
    lua_pushstring(state, domain == ModuleDomain::configuration ? configuration : package);
    return lua_error(state);
  }

  inline static int require(lua_State *state) {
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
    if (directory.size() + name.size() + sizeof("/init.lua") > path.size()) {
      return raise(state, "Local module path is too long", "module path too long");
    }

    std::memcpy(path.data(), directory.data(), directory.size());
    path[directory.size()] = '/';
    auto *suffix = path.data() + directory.size() + 1;
    std::transform(name.begin(), name.end(), suffix, [](char byte) { return byte == '.' ? '/' : byte; });
    std::array<char, PATH_MAX> canonical;
    // A folder module, such as mods/tabs/init.lua, answers to the folder's name.
    bool found = false;
    for (const std::string_view ending : {std::string_view{".lua"}, std::string_view{"/init.lua"}}) {
      std::memcpy(suffix + name.size(), ending.data(), ending.size());
      suffix[name.size() + ending.size()] = '\0';
      if (::realpath(path.data(), canonical.data()) != nullptr) {
        found = true;
        break;
      }
    }

    if (!found) {
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

  static constexpr int module_limit = 1024;
  FixedText<PATH_MAX> directory_;
  int cache_ = LUA_NOREF;
  int loaded_ = 0;
};

}
}

// Interface: telar_lua/value.cppm
export {
namespace telar::runtime::lua {

class Value {
public:
  inline explicit Value(lua_State *state, int index, std::string_view label)
      : state_(state),
        index_(lua_absindex(state, index)),
        restored_top_(lua_gettop(state)),
        label_(label) {}

  inline ~Value() {
    lua_settop(state_, restored_top_);
  }

  Value(const Value &) = delete;
  Value &operator=(const Value &) = delete;

  // The same value under another name: a profile's tables are reported as
  // the configuration's, as Zig's diagnostics name them.
  inline Value as(std::string_view label) const {
    return Value{state_, index_, label};
  }

  inline Value field(const char *name) const {
    require(LUA_TTABLE, "must be a table");
    return Value{*this, name};
  }

  inline Value element(lua_Integer position) const {
    require(LUA_TTABLE, "must be an array");
    return Value{*this, position};
  }

  inline Value entry(std::string_view key) const {
    require(LUA_TTABLE, "must be a table");
    return Value{*this, key};
  }

  inline bool present() const noexcept {
    return lua_type(state_, index_) != LUA_TNIL;
  }

  inline bool is(int type) const noexcept {
    return lua_type(state_, index_) == type;
  }

  inline void pushCopy() const {
    lua_pushvalue(state_, index_);
  }

  inline std::string_view string() const {
    require(LUA_TSTRING, "must be a string");
    std::size_t size = 0;
    const auto *text = lua_tolstring(state_, index_, &size);
    return {text, size};
  }

  inline bool boolean(bool fallback) const {
    if (!present()) {
      return fallback;
    }

    require(LUA_TBOOLEAN, "must be a boolean");
    return lua_toboolean(state_, index_) != 0;
  }

  inline lua_Integer integer() const {
    int valid = 0;
    const auto result = lua_tointegerx(state_, index_, &valid);
    if (!valid) {
      fail("must be an integer");
    }

    return result;
  }

  inline std::optional<lua_Integer> asInteger() const noexcept {
    int valid = 0;
    const auto result = lua_tointegerx(state_, index_, &valid);
    return valid ? std::optional{result} : std::nullopt;
  }

  inline std::uint64_t boundedInteger(std::uint64_t fallback, std::uint64_t minimum, std::uint64_t maximum) const {
    if (!present()) {
      return fallback;
    }

    const auto result = integer();
    if (result < 0 || static_cast<std::uint64_t>(result) < minimum || static_cast<std::uint64_t>(result) > maximum) {
      fail("is outside its bounds");
    }

    return static_cast<std::uint64_t>(result);
  }

  inline double boundedNumber(double fallback, double minimum, double maximum) const {
    if (!present()) {
      return fallback;
    }

    require(LUA_TNUMBER, "must be a number");
    const auto result = lua_tonumber(state_, index_);
    if (!std::isfinite(result) || result < minimum || result > maximum) {
      fail("is outside its bounds");
    }

    return result;
  }

  inline void onlyFields(std::initializer_list<std::string_view> allowed, bool allow_children = false) const {
    onlyFields(std::span<const std::string_view>{allowed.begin(), allowed.size()}, allow_children);
  }

  inline void onlyFields(std::span<const std::string_view> allowed, bool allow_children = false) const {
    require(LUA_TTABLE, "must be a table");
    const auto children = allow_children ? lua_rawlen(state_, index_) : 0;
    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      if (children != 0 && lua_isinteger(state_, -2)) {
        const auto position = lua_tointeger(state_, -2);
        if (position < 1 || static_cast<std::uint64_t>(position) > children) {
          fail("children must form an array");
        }
        lua_pop(state_, 1);
        continue;
      }

      {
        const Value key{state_, -2, label_};
        const auto name = key.string();
        if (std::find(allowed.begin(), allowed.end(), name) == allowed.end()) {
          throw Error{"unknown field " + label_ + "." + std::string{name}};
        }
      }

      lua_pop(state_, 1);
    }
  }

  inline std::size_t arraySize() const {
    require(LUA_TTABLE, "must be an array");
    const auto size = lua_rawlen(state_, index_);
    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      int valid = 0;
      const auto key = lua_tointegerx(state_, -2, &valid);
      if (!valid || lua_type(state_, -2) != LUA_TNUMBER || key < 1 || static_cast<std::uint64_t>(key) > size) {
        fail("contains a non-array key");
      }

      lua_pop(state_, 1);
    }

    return size;
  }

  inline std::size_t listLength() const {
    require(LUA_TTABLE, "must be a table");
    return lua_rawlen(state_, index_);
  }

  template <typename Consumer>
  inline void eachField(Consumer &&consume) const {
    require(LUA_TTABLE, "must be a table");
    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      {
        const Value key{state_, -2, label_};
        const Value value{state_, -1, label_};
        consume(key.string(), value);
      }
      lua_pop(state_, 1);
    }
  }

  [[noreturn]] inline void fail(const char *message) const {
    std::array<char, 512> description;
    std::snprintf(description.data(), description.size(), "%s %s", label_.c_str(), message);
    throw Error{description.data()};
  }

private:
  inline Value(const Value &parent, std::string_view key)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_) {
    lua_pushlstring(state_, key.data(), key.size());
    lua_rawget(state_, parent.index_);
  }

  // A field names its whole path, as Zig's diagnostics do: config.client.sidebar.visible.
  inline Value(const Value &parent, const char *name)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_ + "." + name) {
    lua_getfield(state_, parent.index_, name);
  }

  inline Value(const Value &parent, lua_Integer position)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_) {
    lua_rawgeti(state_, parent.index_, position);
  }

  inline void require(int type, const char *message) const {
    if (lua_type(state_, index_) != type) {
      fail(message);
    }
  }

  lua_State *state_;
  int index_;
  int restored_top_;
  std::string label_;
};

}
}
