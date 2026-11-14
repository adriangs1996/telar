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
  template <Allocator Memory>
  String<Memory> pluginCallbackSource(Memory& memory, std::string_view source, std::string_view action);

  extern template String<Memory> pluginCallbackSource<Memory>(Memory& memory, std::string_view source, std::string_view action);

  int retainPluginCallback(lua_State* state, const config::RetainedActionValidator& validator, config::LimitNotices& limits);

  template <Allocator Memory>
  void runPluginWorker(Memory& memory, const PluginWorkerOptions& options);

  extern template void runPluginWorker<Memory>(Memory& memory, const PluginWorkerOptions& options);

  template <Allocator Memory>
  void runRedirect(Memory& memory, std::span<char* const> arguments, bool cleanup);

  extern template void runRedirect<Memory>(Memory& memory, std::span<char* const> arguments, bool cleanup);

  template <ConcurrentAllocator Memory>
  void runRuntime(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths, const config::RuntimeValues<Memory>& configuration);

  extern template void runRuntime<ConcurrentMemory>(ConcurrentMemory& memory, const ServerOptions& options, const RuntimePaths<ConcurrentMemory>& paths, const config::RuntimeValues<ConcurrentMemory>& configuration);

  template <ConcurrentAllocator Memory>
  void runServer(Memory& memory, const ServerOptions& options);

  extern template void runServer<ConcurrentMemory>(ConcurrentMemory& memory, const ServerOptions& options);

  template <Allocator Memory>
  void runTraffic(Memory& memory, std::span<char* const> arguments);

  extern template void runTraffic<Memory>(Memory& memory, std::span<char* const> arguments);

}
