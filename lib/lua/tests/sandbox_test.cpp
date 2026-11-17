#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <lua.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.lua;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::string_view text(lua_State* state, int index) {
    std::size_t size = 0;
    const char* bytes = lua_tolstring(state, index, &size);

    return bytes == nullptr ? std::string_view{} : std::string_view{bytes, size};
  }

  bool executeRefused(lua::Vm<Memory>& vm, std::string_view source) {
    try {
      vm.execute(source, "@chunk");
    } catch (const lua::Error&) {
      return true;
    }

    return false;
  }

  // Configuration and plugin code runs with exactly these globals: anything else, a loader of
  // files or bytecode included, is out of the sandbox, and so is a binary chunk.
  void testSandboxGlobals() {
    SystemAllocator system;
    MemoryAdapter memory{system};
    lua::Vm<Memory> vm{memory};

    vm.execute(R"lua(
local names = {}
for name in pairs(_G) do names[#names + 1] = name end
table.sort(names)
return table.concat(names, ',')
)lua",
        "@globals");
    constexpr std::string_view allowed = "_G,_VERSION,assert,coroutine,error,ipairs,math,next,os,pairs,pcall,rawequal,rawget,rawlen,select,string,table,tonumber,tostring,type,utf8,warn,xpcall";
    const auto globals = text(vm.state(), -1);

    check(globals == allowed, globals);
    lua_settop(vm.state(), 0);

    vm.execute("return string.dump(function() return 1 end)", "@dump");
    const std::string bytecode{text(vm.state(), -1)};

    lua_settop(vm.state(), 0);
    check(bytecode.starts_with("\x1bLua"));
    check(executeRefused(vm, bytecode));
    check(executeRefused(vm, "\x1bLua"));
  }

  // os.date hands its format to strftime, so it takes only the conversions C defines, a format
  // of at most 64 bytes, and nothing past its 256-byte output.
  void testOsDateRestrictions() {
    SystemAllocator system;
    MemoryAdapter memory{system};
    lua::Vm<Memory> vm{memory};

    vm.execute(R"lua(
assert(not pcall(os.date, '%Q'))
assert(not pcall(os.date, '%'))
assert(not pcall(os.date, 'abc%'))
assert(not pcall(os.date, string.rep('a', 65)))
assert(pcall(os.date, string.rep('a', 64)))
assert(not pcall(os.time, 0))
assert(os.date('!%Y-%m-%d', 0) == '1970-01-01')
assert(#os.date(string.rep('%c', 32)) <= 256)
return true
)lua",
        "@date");
    check(lua_toboolean(vm.state(), -1));
  }

  const telar::testing::Case case_sandbox_globals{"lua.sandbox_globals", testSandboxGlobals};
  const telar::testing::Case case_os_date{"lua.os_date_restrictions", testOsDateRestrictions};

}
