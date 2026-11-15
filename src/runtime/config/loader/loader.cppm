module;

export module telar.runtime.config.loader;

import std;

import telar.config.snapshot;
export import telar.platform.paths;
import telar.base.memory.allocators;
import telar.config.runtime;

export namespace telar::runtime::config {

  // The Lua that every configuration VM runs first.
  inline constexpr std::string_view bootstrap{
#include "config_bootstrap.inc"
  };

  template <Allocator Memory>
  class Loader {
  public:
    explicit Loader(Memory& memory, RuntimeValues<Memory>& values);

    template <EnvironmentLookup Environment>
    void load(const cli::ServerOptions& options, const Environment& environment);

  private:
    String<Memory> readSource(const char* path) const;

    Memory& memory_;
    RuntimeValues<Memory>& values_;
  };

  template <Allocator Memory>
  Loader(Memory& memory, RuntimeValues<Memory>& values) -> Loader<Memory>;

  extern template class Loader<Memory>;
  extern template void Loader<Memory>::load<ProcessEnvironment>(const cli::ServerOptions& options, const ProcessEnvironment& environment);
  extern template class Loader<ConcurrentMemory>;
  extern template void Loader<ConcurrentMemory>::load<ProcessEnvironment>(const cli::ServerOptions& options, const ProcessEnvironment& environment);

}
