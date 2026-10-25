#include "check.hpp"
#include "lua/json.hpp"
#include "lua/vm.hpp"

using namespace telar::runtime;

static int failWithResource(lua_State *state) {
  struct Resource {
    bool *destroyed;

    ~Resource() {
      *destroyed = true;
    }
  } resource{static_cast<bool *>(lua_touserdata(state, 1))};

  return luaL_error(state, "Intentional callback failure");
}

static void testLuaFailures(SystemAllocator &system) {
  BudgetAllocator memory{system, 32 * 1024 * 1024};
  {
    lua::Vm vm{memory};
    bool destroyed = false;
    bool failed = false;
    try {
      vm.invoke(&failWithResource, &destroyed, 0);
    } catch (const lua::Error &error) {
      failed = std::string_view{error.what()}.contains("Intentional callback failure");
    }
    check(failed && destroyed);
    lua_settop(vm.state(), 0);

    failed = false;
    vm.resetBudget();
    try {
      vm.execute("while true do end", "@loop");
    } catch (const lua::Error &error) {
      failed = std::string_view{error.what()}.contains("budget exceeded");
    }
    check(failed);
    lua_settop(vm.state(), 0);

    failed = false;
    vm.resetBudget();
    try {
      vm.execute("return string.rep('x', 32 * 1024 * 1024)", "@memory");
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    check(failed);
  }
  check(memory.liveBytes() == 0);

  BudgetAllocator insufficient{system, 32};
  bool failed = false;
  try {
    lua::Vm vm{insufficient};
  } catch (const std::bad_alloc &) {
    failed = true;
  }
  check(failed && insufficient.liveBytes() == 0);
}

static void testLuaJson(SystemAllocator &system) {
  BudgetAllocator memory{system, 32 * 1024 * 1024};
  {
    lua::Vm vm{memory};
    lua_newtable(vm.state());
    lua::JsonDecoder<decltype(memory)>::install(vm.state(), memory);
    lua_setglobal(vm.state(), "telar");
    vm.execute(R"lua(
local decode = telar.json.decode
local value = decode([[{"array":[1,null,false,"café\uD83D\uDE00"],"nested":{"nul\u0000key":true},"empty":{}}]])
assert(value.array[1] == 1 and value.array[2] == nil and value.array[3] == false and value.array[4] == 'café😀')
assert(value.nested['nul\0key'] and next(value.empty) == nil)
assert(decode('null') == nil and decode('true') == true and decode('false') == false)
assert(math.type(decode('9223372036854775807')) == 'integer')
assert(math.type(decode('9223372036854775808')) == 'float')
assert(math.type(decode('1.0')) == 'float' and decode('1e309') == math.huge)
for _, input in ipairs({'', '01', '1.', '[1,]', '{"a":0,"a":1}', '{"a":null,"\\u0061":0}', '"\\ud800"', '"\\udfff"', '"'..string.char(255)..'"'}) do
  assert(not pcall(decode, input), input)
end
assert(not pcall(decode, {}))
assert(not pcall(decode, string.rep(' ',1024*1024+1)))
assert(decode(string.rep('[',63)..'0'..string.rep(']',63)))
assert(not pcall(decode, string.rep('[',64)..'0'..string.rep(']',64)))
return true
)lua",
               "@json");
    check(lua_toboolean(vm.state(), -1));
  }
  check(memory.liveBytes() == 0);
}

void testLua() {
  SystemAllocator system;
  {
    lua::Vm vm{system};
    vm.execute("return _VERSION == 'Lua 5.5' and utf8.len('café 好') == 6 and io == nil and os == nil and debug == nil and load == nil and setmetatable == nil", "@sandbox");
    check(lua_toboolean(vm.state(), -1));
  }
  testLuaFailures(system);
  testLuaJson(system);
}
