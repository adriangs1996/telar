module;
#include <lua.h>

export module telar.runtime.cli.server;

import std;

export import telar.config.client;
export import telar.config.runtime;
export import telar.platform.paths;

export namespace telar::runtime::cli {

  using PluginWorkerOptions = config::PluginWorkerOptions;

  // Keep the reference worker lexical scope and its mutable Lua binding factory.
  String<Memory> pluginCallbackSource(Memory& memory, std::string_view source, std::string_view action);

  int retainPluginCallback(lua_State* state, const config::RetainedActionValidator& validator, config::LimitNotices& limits);

  void runPluginWorker(Memory& memory, const PluginWorkerOptions& options);

  void runRedirect(Memory& memory, std::span<char* const> arguments, bool cleanup);

  void runRuntime(ConcurrentMemory& memory, const ServerOptions& options, const RuntimePaths<ConcurrentMemory>& paths, const config::RuntimeValues<ConcurrentMemory>& configuration);

  void runServer(ConcurrentMemory& memory, const ServerOptions& options);

  void runTraffic(Memory& memory, std::span<char* const> arguments);

}
