module telar.runtime.server.config.loader;

import telar.lua;
import telar.platform.error;
import telar.platform.fs;
import telar.sys.posix;
import telar.config.core;
import telar.config.snapshot;
import telar.base.ds;

namespace telar::runtime::config {

  template <Allocator Memory>
  Loader<Memory>::Loader(Memory& memory, RuntimeValues<Memory>& values)
      : memory_(memory),
        values_(values) {}

  template <Allocator Memory>
  template <EnvironmentLookup Environment>
  void Loader<Memory>::load(const cli::ServerOptions& options, const Environment& environment) {
    if (options.no_config) {
      return;
    }

    ds::String<Memory> path{memory_, options.config};
    if (path.empty()) {
      path = cli::RuntimePaths<Memory>::configFile(memory_, environment);
      if (path.empty()) {
        throw lua::Error{"Home directory unavailable for configuration"};
      }
    }

    ds::Array<char, PATH_MAX> canonical{};
    if (::realpath(path.data(), canonical.dataMut()) == nullptr) {
      if (sys::lastError() == ENOENT && options.config.empty() && options.profile.empty()) {
        return;
      }

      throw SystemError{"Resolve runtime configuration"};
    }

    const std::string_view resolved{canonical.data()};
    const auto directory = resolved.substr(0, resolved.rfind('/'));
    const auto source = readSource(canonical.data());
    lua::Vm machine{memory_};

    machine.resetBudget();
    machine.execute(bootstrap, "@telar/bootstrap.lua", 0);
    lua_getglobal(machine.state(), "telar");
    lua::JsonDecoder<Memory>::install(machine.state(), memory_);
    lua_pop(machine.state(), 1);
    LocalModules modules{machine.state(), directory};

    machine.execute(source, "@config.lua");
    const lua::Value root{machine.state(), -1, "config"};

    SnapshotReader{memory_, values_}.read(root, options.profile);
    resolveRelativePath(values_.history_path, directory);
    resolveRelativePath(values_.session_path, directory);
    resolveRelativePath(values_.proxy.authority_directory, directory);
    values_.configuration_directory.assign(directory.empty() ? "/" : directory);
  }

  template <Allocator Memory>
  ds::String<Memory> Loader<Memory>::readSource(const char* path) const {
    try {
      constexpr std::size_t maximum_source_bytes = std::size_t{1024} * 1024;

      return readFile(memory_, path, maximum_source_bytes);
    } catch (const FileReadError& error) {
      if (error.failure() == FileReadFailure::invalid_size) {
        throw lua::Error{"Configuration must be a regular file of at most 1 MiB"};
      }

      throw lua::Error{"Configuration changed while reading"};
    } catch (const SystemError& error) {
      throw SystemError{"Open runtime configuration", error.code()};
    }
  }

  template class Loader<Memory>;
  template void Loader<Memory>::load<ProcessEnvironment>(const cli::ServerOptions& options, const ProcessEnvironment& environment);
  template class Loader<ConcurrentMemory>;
  template void Loader<ConcurrentMemory>::load<ProcessEnvironment>(const cli::ServerOptions& options, const ProcessEnvironment& environment);

}
