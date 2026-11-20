export module telar.runtime.server.server;

import std;
import telar.tbc;
import telar.lua;

import telar.config.client;
import telar.config.runtime;
import telar.platform.paths;
import telar.base.memory.allocators;
import telar.config.core;
import telar.base.ds;

export namespace telar::runtime::cli {

  using config::PluginWorkerOptions;

  // Keep the reference worker lexical scope and its mutable Lua binding factory.
  tbc::val_a<ds::String<Memory>> pluginCallbackSource(tbc::mut_a<Memory> memory, std::string_view source, std::string_view action);

  int retainPluginCallback(lua_State* state, config::RetainedActionValidator& validator, config::LimitNotices& limits);

  void runPluginWorker(Memory& memory, const PluginWorkerOptions& options);

  void runRedirect(Memory& memory, std::span<char* const> arguments, bool cleanup);

  void runRuntime(ConcurrentMemory& memory, const ServerOptions& options, const RuntimePaths<ConcurrentMemory>& paths, const config::RuntimeValues<ConcurrentMemory>& configuration);

  void runServer(ConcurrentMemory& memory, const ServerOptions& options);

  void runTraffic(Memory& memory, std::span<char* const> arguments);

}
