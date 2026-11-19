export module telar.runtime.cli.server;

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

  using PluginWorkerOptions = config::PluginWorkerOptions;

  // Keep the reference worker lexical scope and its mutable Lua binding factory.
  tbc::view<ds::String<Memory>, tbc::lt::a> pluginCallbackSource(tbc::view<Memory&, tbc::lt::a> memory, std::string_view source, std::string_view action);

  int retainPluginCallback(lua_State* state, config::RetainedActionValidator& validator, config::LimitNotices& limits);

  void runPluginWorker(Memory& memory, const PluginWorkerOptions& options);

  void runRedirect(Memory& memory, std::span<char* const> arguments, bool cleanup);

  void runRuntime(ConcurrentMemory& memory, const ServerOptions& options, const RuntimePaths<ConcurrentMemory>& paths, const config::RuntimeValues<ConcurrentMemory>& configuration);

  void runServer(ConcurrentMemory& memory, const ServerOptions& options);

  void runTraffic(Memory& memory, std::span<char* const> arguments);

}
