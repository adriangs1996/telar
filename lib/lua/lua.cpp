module;
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

module telar.lua;

import std;
import telar.tbc;
import telar.sys.posix;
import telar.base.text.utf8;
import telar.base.ds;

// The parentheses keep each name from expanding as the macro the body calls.
void(lua_call)(lua_State* state, int arguments, int results) {
  lua_call(state, arguments, results);
}

void(lua_newtable)(lua_State* state) {
  lua_newtable(state);
}

void(lua_pop)(lua_State* state, int count) {
  lua_pop(state, count);
}

void(lua_remove)(lua_State* state, int index) {
  lua_remove(state, index);
}

void(lua_replace)(lua_State* state, int index) {
  lua_replace(state, index);
}

bool(lua_isfunction)(lua_State* state, int index) {
  return lua_isfunction(state, index);
}

bool(lua_isnil)(lua_State* state, int index) {
  return lua_isnil(state, index);
}

bool(lua_istable)(lua_State* state, int index) {
  return lua_istable(state, index);
}

int(lua_pcall)(lua_State* state, int arguments, int results, int handler) {
  return lua_pcall(state, arguments, results, handler);
}

void(lua_pushcfunction)(lua_State* state, lua_CFunction function) {
  lua_pushcfunction(state, function);
}

// lua_pushliteral pastes "" before a literal; the text here is already a pointer.
auto(lua_pushliteral)(lua_State* state, const char* text) -> const char* {
  return lua_pushstring(state, text);
}

lua_Integer(lua_tointeger)(lua_State* state, int index) {
  return lua_tointeger(state, index);
}

auto(lua_tostring)(lua_State* state, int index) -> const char* {
  return lua_tostring(state, index);
}

namespace telar::runtime::lua {
  namespace {

    // luaL_error without its format: the message prefixed with where the running chunk stands.
    int raiseError(lua_State* state, const char* message) {
      luaL_where(state, 1);
      lua_pushstring(state, message);
      lua_concat(state, 2);
      return lua_error(state);
    }

    // The block Lua sees follows its allocation's header, which records the block's capacity.
    template <typename Header>
    void* pastHeader(Header* header) noexcept {
      return header + 1; // NOLINT(clang-diagnostic-unsafe-buffer-usage): lua_Alloc trades raw blocks, each right after its header
    }

    template <typename Header>
    Header* headerOf(void* block) noexcept {
      return static_cast<Header*>(block) - 1; // NOLINT(clang-diagnostic-unsafe-buffer-usage): lua_Alloc trades raw blocks, each right after its header
    }

    int panic(lua_State* state) {
      std::size_t size = 0;
      const auto* message = lua_tolstring(state, -1, &size);

      throw Error{message == nullptr ? std::string_view{"Unprotected Lua failure"} : std::string_view{message, size}};
    }

    int osTime(lua_State* state) {
      if (!lua_isnoneornil(state, 1)) {
        return raiseError(state, "os.time accepts no arguments");
      }

      lua_pushinteger(state, static_cast<lua_Integer>(std::time(nullptr)));

      return 1;
    }

    int osClock(lua_State* state) {
      lua_pushnumber(state, static_cast<lua_Number>(std::clock()) / static_cast<lua_Number>(CLOCKS_PER_SEC));

      return 1;
    }

    int osDate(lua_State* state) {
      constexpr std::string_view allowed{"aAbBcdDeFHIjmMnpRSTuUVwWxXyYzZ%"};
      constexpr std::size_t maximum_format_bytes = 64;
      constexpr std::size_t maximum_output_bytes = 256;
      std::size_t size = 0;
      const char* bytes = luaL_optlstring(state, 1, "%c", &size);
      std::string_view format{bytes, size};
      const auto when = static_cast<std::time_t>(luaL_optinteger(state, 2, static_cast<lua_Integer>(std::time(nullptr))));
      const bool utc = format.starts_with('!');
      if (utc) {
        format.remove_prefix(1);
      }

      if (format.size() > maximum_format_bytes) {
        return raiseError(state, "os.date format exceeds 64 bytes");
      }

      for (std::size_t index = 0; index < format.size(); ++index) {
        if (format[index] != '%') {
          continue;
        }

        ++index;
        if (index == format.size() || !allowed.contains(format[index])) {
          return raiseError(state, "os.date format uses an unsupported conversion");
        }
      }

      std::tm calendar{};
      if ((utc ? ::gmtime_r(&when, &calendar) : ::localtime_r(&when, &calendar)) == nullptr) {
        return raiseError(state, "os.date time is out of range");
      }

      ds::Array<char, maximum_format_bytes + 1> pattern{};

      std::ranges::copy(format, pattern.viewMut().begin());
      ds::Array<char, maximum_output_bytes> output{};
      const auto written = format.empty() ? 0 : std::strftime(output.dataMut(), output.size(), pattern.data(), &calendar);

      lua_pushlstring(state, output.data(), written);

      return 1;
    }

    // A registry reference to a new table that caches the loaded modules by name.
    int newModuleCache(lua_State* state) {
      constexpr int expected_modules = 16;

      lua_createtable(state, 0, expected_modules);
      return luaL_ref(state, LUA_REGISTRYINDEX);
    }

    // Writes the canonical path of module `name` under `directory` to `canonical`: name.lua, or
    // name/init.lua for a folder module, such as mods/tabs/init.lua, which answers to the folder's
    // name. The caller checked that the longer of the two fits.
    bool resolveModule(std::string_view directory, std::string_view name, ds::Array<char, PATH_MAX>& canonical) {
      ds::Array<char, PATH_MAX> path{};

      std::ranges::copy(directory, path.viewMut().begin());
      path.atMut(directory.size()) = '/';
      std::ranges::transform(name, path.viewMut().subspan(directory.size() + 1).begin(), [](char byte) {
        return byte == '.' ? '/' : byte;
      });

      for (const std::string_view ending : {std::string_view{".lua"}, std::string_view{"/init.lua"}}) {
        auto tail = path.viewMut().subspan(directory.size() + 1 + name.size());

        std::ranges::copy(ending, tail.begin());
        tail[ending.size()] = '\0';
        if (::realpath(path.data(), canonical.dataMut()) != nullptr) {
          return true;
        }
      }

      return false;
    }

    int openSandbox(lua_State* state) {
      constexpr ds::Array libraries{
          luaL_Reg{.name = "_G", .func = luaopen_base},
          luaL_Reg{.name = LUA_COLIBNAME, .func = luaopen_coroutine},
          luaL_Reg{.name = LUA_MATHLIBNAME, .func = luaopen_math},
          luaL_Reg{.name = LUA_STRLIBNAME, .func = luaopen_string},
          luaL_Reg{.name = LUA_TABLIBNAME, .func = luaopen_table},
          luaL_Reg{.name = LUA_UTF8LIBNAME, .func = luaopen_utf8},
      };

      for (const auto& library : libraries) {
        luaL_requiref(state, library.name, library.func, 1);
        lua_pop(state, 1);
      }

      for (const auto* name : {"collectgarbage", "dofile", "getmetatable", "load", "loadfile", "print", "rawset", "setmetatable"}) {
        lua_pushnil(state);
        lua_setglobal(state, name);
      }

      // Only the clock: the standard os library also spawns processes and reads the environment.
      constexpr ds::Array clock{
          luaL_Reg{.name = "time", .func = &osTime},
          luaL_Reg{.name = "clock", .func = &osClock},
          luaL_Reg{.name = "date", .func = &osDate},
      };

      lua_createtable(state, 0, static_cast<int>(clock.size()));
      for (const auto& function : clock) {
        lua_pushcfunction(state, function.func);
        lua_setfield(state, -2, function.name);
      }

      lua_setglobal(state, "os");

      return 0;
    }

  }

  const char* Error::what() const noexcept {
    return message_.c_str();
  }

  template <Allocator Memory>
  Vm<Memory>::Vm(Memory& memory, Limits limits)
      : memory_(memory),
        limits_(limits),
        deadline_(Clock::now() + limits.deadline),
        state_(lua_newstate(&allocate, this, 0)) {
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

  template <Allocator Memory>
  Vm<Memory>::~Vm() {
    lua_close(state_);
  }

  template <Allocator Memory>
  void Vm<Memory>::resetBudget() noexcept {
    instructions_ = 0;
    deadline_ = Clock::now() + limits_.deadline;
  }

  template <Allocator Memory>
  void Vm<Memory>::resetBudget(std::uint64_t instructions, std::chrono::nanoseconds deadline) noexcept {
    limits_.instructions = instructions;
    limits_.deadline = deadline;
    resetBudget();
  }

  template <Allocator Memory>
  void Vm<Memory>::execute(std::string_view source, const char* name, int results) {
    check(luaL_loadbufferx(state_, source.data(), source.size(), name, "t"));
    check(lua_pcall(state_, 0, results, 0));
  }

  template <Allocator Memory>
  void Vm<Memory>::invoke(lua_CFunction function, void* context, int results) {
    lua_pushcfunction(state_, function);
    lua_pushlightuserdata(state_, context);
    check(lua_pcall(state_, 1, results, 0));
  }

  template <Allocator Memory>
  lua_State* Vm<Memory>::state() const noexcept {
    return state_;
  }

  template <Allocator Memory>
  std::size_t Vm<Memory>::usedBytes() const noexcept {
    return used_bytes_;
  }

  template <Allocator Memory>
  Vm<Memory>& Vm<Memory>::owner(lua_State* state) noexcept {
    void* context = nullptr;

    lua_getallocf(state, &context);
    return *static_cast<Vm*>(context);
  }

  template <Allocator Memory>
  void* Vm<Memory>::allocate(void* context, void* pointer, std::size_t old_size, std::size_t new_size) noexcept { // NOLINT(bugprone-easily-swappable-parameters): lua_Alloc's C signature
    auto& machine = *static_cast<Vm*>(context);
    const auto previous = pointer == nullptr ? 0 : old_size;
    const auto retained = machine.used_bytes_ - previous;

    if (new_size == 0) {
      machine.release(pointer);
      machine.used_bytes_ = retained;
      return nullptr;
    }

    if (new_size > machine.limits_.memory - retained || new_size > std::numeric_limits<std::size_t>::max() - sizeof(Allocation)) {
      return nullptr;
    }

    if (pointer != nullptr && new_size <= previous) {
      machine.used_bytes_ = retained + new_size;
      return pointer;
    }

    auto* allocation = static_cast<Allocation*>(machine.memory_.allocate(sizeof(Allocation) + new_size, alignof(Allocation)));
    if (allocation == nullptr) {
      return nullptr;
    }

    allocation->capacity = new_size;
    void* const block = pastHeader(allocation);

    if (pointer != nullptr) {
      std::memcpy(block, pointer, previous); // NOLINT(clang-diagnostic-unsafe-buffer-usage-in-libc-call): lua_Alloc trades raw blocks; `previous` bytes fit both
      machine.release(pointer);
    }

    machine.used_bytes_ = retained + new_size;
    return block;
  }

  template <Allocator Memory>
  void Vm<Memory>::release(void* pointer) noexcept {
    if (pointer != nullptr) {
      auto* allocation = headerOf<Allocation>(pointer);

      memory_.deallocate(allocation, sizeof(Allocation) + allocation->capacity, alignof(Allocation));
    }
  }

  template <Allocator Memory>
  void Vm<Memory>::instructionHook(lua_State* state, lua_Debug* /*record*/) {
    auto& machine = owner(state);

    machine.instructions_ += instruction_interval;
    if (machine.instructions_ > machine.limits_.instructions || Clock::now() > machine.deadline_) {
      raiseError(state, "Telar Lua execution budget exceeded");
    }
  }

  template <Allocator Memory>
  void Vm<Memory>::check(int status) {
    if (status == LUA_OK) {
      return;
    }

    if (status == LUA_ERRMEM) {
      throw std::bad_alloc{};
    }

    panic(state_);
  }

  template class Vm<Memory>;
  template class Vm<ConcurrentMemory>;
  template class Vm<ErasingMemory>;

  template <Allocator Memory>
  void JsonDecoder<Memory>::install(lua_State* state, Memory& memory) {
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, &memory);
    lua_pushcclosure(state, &decode, 1);
    lua_setfield(state, -2, "decode");
    lua_setfield(state, -2, "json");
  }

  template <Allocator Memory>
  JsonDecoder<Memory>::JsonDecoder(Memory& memory)
      : text_(memory) {}

  template <Allocator Memory>
  int JsonDecoder<Memory>::decode(lua_State* state) {
    if (lua_type(state, 1) != LUA_TSTRING) {
      return raiseError(state, "json.decode expects a string");
    }

    std::size_t size = 0;
    const auto* bytes = lua_tolstring(state, 1, &size);

    if (size > maximum_input_bytes) {
      return raiseError(state, "JSON input is too large");
    }

    try {
      const std::string_view input{bytes, size};

      validateUtf8(input);
      const auto document = JsonValue::parse(input, maximum_depth - 1);
      auto& memory = *static_cast<Memory*>(lua_touserdata(state, lua_upvalueindex(1)));
      JsonDecoder decoder{memory};

      decoder.push(state, document, 0);
      return 1;
    } catch (const std::exception& error) {
      return raiseError(state, error.what());
    }
  }

  // NOLINTBEGIN(misc-no-recursion): push and object descend a document's nesting, cut at maximum_depth.
  template <Allocator Memory>
  void JsonDecoder<Memory>::push(lua_State* state, const JsonValue& value, unsigned depth) {
    // The stack slots one level of the document may take.
    constexpr int level_slots = 6;
    if (depth == maximum_depth || (lua_checkstack(state, level_slots) == 0)) {
      throw Error{"JSON exceeds the depth limit"};
    }

    switch (value.encoded().front()) {
    case 'n':
      lua_pushnil(state);
      break;
    case 't':
    case 'f':
      lua_pushboolean(state, static_cast<int>(value.boolean()));
      break;
    case '"':
      value.string(text_);
      lua_pushlstring(state, text_.data(), text_.size());
      break;
    case '[': {
      int count = 0;

      value.eachElement([&](const JsonValue&) {
        ++count;
      });

      lua_createtable(state, count, 0);
      const auto table = lua_absindex(state, -1);
      lua_Integer index = 0;

      value.eachElement([&](const JsonValue& element) {
        push(state, element, depth + 1);
        lua_rawseti(state, table, ++index);
      });

      break;
    }
    case '{':
      object(state, value, depth);
      break;
    default:
      text_.assign(value.encoded());
      if (lua_stringtonumber(state, text_.data()) != text_.size() + 1) {
        throw Error{"JSON number is outside its bounds"};
      }
    }
  }

  template <Allocator Memory>
  void JsonDecoder<Memory>::object(lua_State* state, const JsonValue& value, unsigned depth) {
    int count = 0;

    value.eachMember([&](const JsonValue&, const JsonValue&) {
      ++count;
    });

    lua_createtable(state, 0, count);
    const auto table = lua_absindex(state, -1);

    lua_newtable(state);
    const auto names = lua_absindex(state, -1);

    value.eachMember([&](const JsonValue& key, const JsonValue& member) {
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

  // NOLINTEND(misc-no-recursion)

  template class JsonDecoder<Memory>;
  template class JsonDecoder<ConcurrentMemory>;
  template class JsonDecoder<ErasingMemory>;

  template <ModuleDomain domain>
  LocalModules<domain>::LocalModules(lua_State* state, std::string_view directory)
      : cache_(newModuleCache(state)) {
    directory_.assign(directory);
    lua_pushlightuserdata(state, this);
    lua_pushcclosure(state, &require, 1);
    lua_setglobal(state, "require");
  }

  template <ModuleDomain domain>
  std::size_t LocalModules<domain>::configurationModuleCount() const noexcept
    requires(domain == ModuleDomain::configuration)
  {
    return static_cast<std::size_t>(loaded_);
  }

  template <ModuleDomain domain>
  void LocalModules<domain>::visitNames(lua_State* state, void* target, void (*visit)(void*, std::string_view)) const {
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
        const auto* name = lua_tolstring(state, -2, &length);

        visit(target, std::string_view{name, length});
        lua_pop(state, 1);
      }
    } catch (...) {
      lua_settop(state, initial_top);
      throw;
    }

    lua_settop(state, initial_top);
  }

  template <ModuleDomain domain>
  int LocalModules<domain>::raise(lua_State* state, const char* configuration, const char* package) {
    lua_pushstring(state, domain == ModuleDomain::configuration ? configuration : package);
    return lua_error(state);
  }

  template <ModuleDomain domain>
  int LocalModules<domain>::require(lua_State* state) {
    auto& modules = *static_cast<LocalModules*>(lua_touserdata(state, lua_upvalueindex(1)));

    if (domain == ModuleDomain::configuration && lua_type(state, 1) != LUA_TSTRING) {
      return raiseError(state, "require expects a module name");
    }

    std::size_t size = 0;
    const auto* bytes = lua_tolstring(state, 1, &size);
    if (bytes == nullptr) {
      return raiseError(state, "require expects a module name");
    }

    const std::string_view name{bytes, size};
    if (name == "telar") {
      lua_getglobal(state, "telar");
      return 1;
    }

    if (domain == ModuleDomain::package && name == "telar.traffic") {
      lua_getglobal(state, "telar");
      lua_getfield(state, -1, "traffic");
      if (lua_isnil(state, -1)) {
        return raiseError(state, "Traffic API is unavailable");
      }

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
    ds::Array<char, PATH_MAX> canonical{};
    if (directory.size() + name.size() + sizeof("/init.lua") > canonical.size()) {
      return raise(state, "Local module path is too long", "module path too long");
    }

    if (!resolveModule(directory, name, canonical)) {
      return raise(state, "Cannot resolve local configuration module", "cannot resolve local module");
    }

    const std::string_view resolved{canonical.data()};
    if (!resolved.starts_with(directory) || (resolved.size() != directory.size() && resolved[directory.size()] != '/')) {
      return raise(state, "Local configuration module escapes the configuration directory", "module escapes package");
    }

    struct stat metadata{};
    if (::stat(canonical.data(), &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
      return raiseError(state, "Local configuration module must be a regular file");
    }

    if (luaL_loadfilex(state, canonical.data(), "t") != LUA_OK || lua_pcall(state, 0, 1, 0) != LUA_OK) {
      return lua_error(state);
    }

    if (lua_isnil(state, -1)) {
      lua_pop(state, 1);
      lua_pushboolean(state, 1);
    }

    if (domain == ModuleDomain::configuration && modules.loaded_ == module_limit) {
      return raiseError(state, "Configuration requires too many local modules");
    }

    if constexpr (domain == ModuleDomain::configuration) {
      ++modules.loaded_;
    }

    lua_pushvalue(state, 1);
    lua_pushvalue(state, -2);
    lua_rawset(state, -4);
    return 1;
  }

  template class LocalModules<ModuleDomain::configuration>;
  template class LocalModules<ModuleDomain::package>;

  void setField(lua_State* state, const char* name, std::string_view value) {
    lua_pushlstring(state, value.data(), value.size());
    lua_setfield(state, -2, name);
  }

  void setField(lua_State* state, const char* name, bool value) {
    lua_pushboolean(state, static_cast<int>(value));
    lua_setfield(state, -2, name);
  }

  void setField(lua_State* state, const char* name, lua_Integer value) {
    lua_pushinteger(state, value);
    lua_setfield(state, -2, name);
  }

  void setDecimal(lua_State* state, const char* name, std::uint64_t value) {
    constexpr std::size_t text_bytes = 32;
    ds::Array<char, text_bytes> text{};
    const auto output = text.viewMut();
    const auto result = std::to_chars(output.data(), std::to_address(output.end()), value);

    setField(state, name, std::string_view{text.data(), static_cast<std::size_t>(result.ptr - text.data())});
  }

  void pushReadOnly(lua_State* state, const char* message) {
    lua_createtable(state, 0, 0);
    lua_createtable(state, 0, 3);
    lua_pushvalue(state, -3);
    lua_setfield(state, -2, "__index");
    lua_pushstring(state, message);
    lua_pushcclosure(state, [](lua_State* raised) -> int {
      lua_pushvalue(raised, lua_upvalueindex(1));
      return lua_error(raised);
    },
        1);

    lua_setfield(state, -2, "__newindex");
    lua_pushboolean(state, 0);
    lua_setfield(state, -2, "__metatable");
    lua_setmetatable(state, -2);
    lua_remove(state, -2);
  }

  Value::Value(tbc::val_a<lua_State*> state, int index, std::string_view label)
      : state_(state),
        index_(lua_absindex(state, index)),
        restored_top_(lua_gettop(state)),
        label_(label) {}

  Value::~Value() {
    lua_settop(state_, restored_top_);
  }

  tbc::val_a<Value> Value::as(std::string_view label) const {
    return Value{state_, index_, label};
  }

  tbc::val_a<Value> Value::field(const char* name) const {
    require(LUA_TTABLE, "must be a table");
    return Value{*this, name};
  }

  tbc::val_a<Value> Value::element(lua_Integer position) const {
    require(LUA_TTABLE, "must be an array");
    return Value{*this, position};
  }

  tbc::val_a<Value> Value::entry(std::string_view key) const {
    require(LUA_TTABLE, "must be a table");
    return Value{*this, key};
  }

  bool Value::present() const noexcept {
    return lua_type(state_, index_) != LUA_TNIL;
  }

  bool Value::is(int type) const noexcept {
    return lua_type(state_, index_) == type;
  }

  void Value::pushCopy() const {
    lua_pushvalue(state_, index_);
  }

  tbc::val_a<std::string_view> Value::string() const {
    require(LUA_TSTRING, "must be a string");
    std::size_t size = 0;
    const auto* text = lua_tolstring(state_, index_, &size);

    return {text, size};
  }

  bool Value::boolean(bool fallback) const {
    if (!present()) {
      return fallback;
    }

    require(LUA_TBOOLEAN, "must be a boolean");
    return lua_toboolean(state_, index_) != 0;
  }

  lua_Integer Value::integer() const {
    int valid = 0;
    const auto result = lua_tointegerx(state_, index_, &valid);

    if (valid == 0) {
      fail("must be an integer");
    }

    return result;
  }

  ds::Option<lua_Integer> Value::asInteger() const noexcept {
    int valid = 0;
    const auto result = lua_tointegerx(state_, index_, &valid);

    return (valid != 0) ? ds::Option{result} : ds::none;
  }

  std::uint64_t Value::boundedInteger(std::uint64_t fallback, std::uint64_t minimum, std::uint64_t maximum) const {
    if (!present()) {
      return fallback;
    }

    const auto result = integer();
    if (std::cmp_less(result, minimum) || std::cmp_greater(result, maximum)) {
      fail("is outside its bounds");
    }

    return static_cast<std::uint64_t>(result);
  }

  double Value::boundedNumber(double fallback, double minimum, double maximum) const {
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

  void Value::onlyFields(std::initializer_list<std::string_view> allowed, bool allow_children) const {
    onlyFields(std::span<const std::string_view>{allowed}, allow_children);
  }

  void Value::onlyFields(std::span<const std::string_view> allowed, bool allow_children) const {
    require(LUA_TTABLE, "must be a table");
    const auto children = allow_children ? lua_rawlen(state_, index_) : 0;

    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      if (children != 0 && (lua_isinteger(state_, -2) != 0)) {
        const auto position = lua_tointeger(state_, -2);
        if (position < 1 || std::cmp_greater(position, children)) {
          fail("children must form an array");
        }

        lua_pop(state_, 1);
        continue;
      }

      {
        const Value key{state_, -2, label_.view()};
        const auto name = key.string();
        if (std::ranges::find(allowed, name) == allowed.end()) {
          throw Error{"unknown field ", label_.view(), ".", name};
        }
      }

      lua_pop(state_, 1);
    }
  }

  std::size_t Value::arraySize() const {
    require(LUA_TTABLE, "must be an array");
    const auto size = lua_rawlen(state_, index_);

    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      int valid = 0;
      const auto key = lua_tointegerx(state_, -2, &valid);
      if ((valid == 0) || lua_type(state_, -2) != LUA_TNUMBER || key < 1 || std::cmp_greater(key, size)) {
        fail("contains a non-array key");
      }

      lua_pop(state_, 1);
    }

    return size;
  }

  std::size_t Value::listLength() const {
    require(LUA_TTABLE, "must be a table");
    return lua_rawlen(state_, index_);
  }

  void Value::visitFields(void* target, void (*consume)(void*, std::string_view, const Value&)) const {
    require(LUA_TTABLE, "must be a table");
    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      {
        const Value key{state_, -2, label_.view()};
        const Value value{state_, -1, label_.view()};

        consume(target, key.string(), value);
      }

      lua_pop(state_, 1);
    }
  }

  Value::Value(const Value& parent, std::string_view key)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_) {
    lua_pushlstring(state_, key.data(), key.size());
    lua_rawget(state_, parent.index_);
  }

  Value::Value(const Value& parent, const char* name)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_.view(), ".", name) {
    lua_getfield(state_, parent.index_, name);
  }

  Value::Value(const Value& parent, lua_Integer position)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_) {
    lua_rawgeti(state_, parent.index_, position);
  }

  void Value::require(int type, const char* message) const {
    if (lua_type(state_, index_) != type) {
      fail(message);
    }
  }

}
