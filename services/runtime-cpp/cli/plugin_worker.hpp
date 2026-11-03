#pragma once

#include "config_bootstrap.hpp"
#include "plugin_worker_options.hpp"
#include "plugins/action_encoder.hpp"
#include "telar_config/binding_validator.hpp"
#include "telar_config/callback_invocation.hpp"
#include "telar_config/local_modules.hpp"
#include "telar_lua/json.hpp"
#include "telar_platform/read_file.hpp"
#include "telar_platform/write_descriptor.hpp"
#include <filesystem>
#include <unistd.h>

namespace telar::runtime::cli {

// Keep the reference worker lexical scope and its mutable Lua binding factory.
template <Allocator Memory>
String<Memory> pluginCallbackSource(Memory &memory, std::string_view source, std::string_view action) {
  constexpr std::string_view prefix = "local telar = require(\"telar\")\nlocal plugin = (function()\n";
  constexpr std::string_view middle = "\nend)()\nif type(plugin) ~= \"table\" or type(plugin.actions) ~= \"table\" then error(\"plugin must return a table with an actions table\") end\nlocal callback = plugin.actions[\"";
  constexpr std::string_view suffix = "\"]\nif type(callback) ~= \"function\" then error(\"plugin action is not a function\") end\nreturn {telar.bind_global({\"escape\"}, callback)}";
  String<Memory> wrapped{AllocatorRef<char, Memory>{memory}};
  wrapped.reserve(prefix.size() + source.size() + middle.size() + action.size() + suffix.size());
  wrapped.append(prefix).append(source).append(middle).append(action).append(suffix);

  return wrapped;
}

inline int retainPluginCallback(lua_State *state, const config::RetainedActionValidator &validator, config::LimitNotices &limits) {
  const lua::Value bindings{state, -1, "plugin binding"};
  config::BindingKeymap keymap;
  config::BindingValidator::validate(bindings, validator, keymap, limits);
  const auto binding = bindings.element(1);
  const auto callback = binding.field("action");
  if (!callback.is(LUA_TFUNCTION) || binding.field("expression").boolean(false)) {
    callback.fail("must be an action callback");
  }

  callback.pushCopy();
  return luaL_ref(state, LUA_REGISTRYINDEX);
}

template <Allocator Memory>
void runPluginWorker(Memory &memory, const PluginWorkerOptions &options) {
  constexpr std::size_t maximum_source_bytes = std::size_t{1024} * 1024;
  const auto source = readFile(memory, options.entry, maximum_source_bytes);
  const auto directory = std::filesystem::canonical(std::filesystem::absolute(options.entry).parent_path()).string();
  lua::Vm vm{memory};
  vm.resetBudget();
  vm.execute(config::bootstrap, "@telar/bootstrap.lua", 0);
  lua_getglobal(vm.state(), "telar");
  lua::JsonDecoder<Memory>::install(vm.state(), memory);
  lua_pop(vm.state(), 1);
  config::LocalModules modules{vm.state(), directory};
  const auto wrapped = pluginCallbackSource(memory, source, options.action);
  config::LimitNotices limits;
  config::RetainedCommandTabRegistry commands;
  lua_pushnil(vm.state());
  const lua::Value empty{vm.state(), -1, "client"};
  const config::ClientDefinitions definitions{empty};
  const config::RetainedActionValidator validator{definitions, limits, commands};
  vm.execute(wrapped, "@plugin-worker.lua");
  const int reference = retainPluginCallback(vm.state(), validator, limits);
  lua_settop(vm.state(), 1);

  config::CallbackInvocation invocation{reference, options.context};
  constexpr std::uint64_t callback_instructions = 100'000;
  constexpr auto callback_deadline = std::chrono::milliseconds{100};
  vm.resetBudget(callback_instructions, callback_deadline);
  vm.invoke(&config::CallbackInvocation::invoke, &invocation, 1);
  const lua::Value result{vm.state(), -1, "plugin callback result"};
  plugins::ActionEncoder encoder{validator};
  const auto encoded = encoder.encode(result);

  // No bytes escape until the entire callback batch has passed validation.
  if (const int error = writeDescriptor(STDOUT_FILENO, encoded); error != 0) {
    throw SystemError{"Write plugin worker effects", error};
  }
}

}
