#pragma once

#include "config_bootstrap.hpp"
#include "telar_config/local_modules.hpp"
#include "telar_config/snapshot_reader.hpp"
#include "telar_lua/json.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/process_environment.hpp"
#include "telar_platform/read_file.hpp"
#include "telar_platform/resolve_relative_path.hpp"
#include "telar_platform/server_options.hpp"
#include <fcntl.h>
#include <sys/stat.h>

namespace telar::runtime::config {

template <Allocator Memory>
class Loader {
public:
  explicit Loader(Memory &memory, RuntimeValues<Memory> &values)
      : memory_(memory),
        values_(values) {}

  template <EnvironmentLookup Environment>
  void load(const cli::ServerOptions &options, const Environment &environment) {
    if (options.no_config) {
      return;
    }

    String<Memory> path{options.config, AllocatorRef<char, Memory>{memory_}};
    if (path.empty()) {
      const auto development = environment.lookup("TELAR_DEVELOPMENT_CONFIG");
      const auto config_home = environment.lookup("XDG_CONFIG_HOME");
      if (!development.empty()) {
        path = development;
      } else if (!config_home.empty()) {
        path = config_home;
        path += "/telar/config.lua";
      } else {
        const auto home = environment.lookup("HOME");
        if (home.empty()) {
          throw lua::Error{"Home directory unavailable for configuration"};
        }

        path = home;
        path += "/.config/telar/config.lua";
      }
    }

    std::array<char, PATH_MAX> canonical;
    if (::realpath(path.c_str(), canonical.data()) == nullptr) {
      if (errno == ENOENT && options.config.empty() && options.profile.empty()) {
        return;
      }

      throw SystemError{"Resolve runtime configuration"};
    }

    const std::string_view resolved{canonical.data()};
    const auto directory = resolved.substr(0, resolved.rfind('/'));
    const auto source = readSource(canonical.data());
    lua::Vm vm{memory_};
    vm.resetBudget();
    vm.execute(bootstrap, "@telar/bootstrap.lua", 0);
    lua_getglobal(vm.state(), "telar");
    lua::JsonDecoder<Memory>::install(vm.state(), memory_);
    lua_pop(vm.state(), 1);
    LocalModules modules{vm.state(), directory};
    vm.execute(source, "@config.lua");
    const lua::Value root{vm.state(), -1, "config"};
    SnapshotReader{memory_, values_}.read(root, options.profile);
    resolveRelativePath(values_.history_path, directory);
    resolveRelativePath(values_.session_path, directory);
    resolveRelativePath(values_.proxy.authority_directory, directory);
    values_.configuration_directory.assign(directory.empty() ? "/" : directory);
  }

private:
  String<Memory> readSource(const char *path) const {
    try {
      return readFile(memory_, path, 1024 * 1024);
    } catch (const FileReadError &error) {
      if (error.failure() == FileReadFailure::invalid_size) {
        throw lua::Error{"Configuration must be a regular file of at most 1 MiB"};
      }
      throw lua::Error{"Configuration changed while reading"};
    } catch (const SystemError &error) {
      throw SystemError{"Open runtime configuration", error.code()};
    }
  }

  Memory &memory_;
  RuntimeValues<Memory> &values_;
};

template <Allocator Memory>
Loader(Memory &memory, RuntimeValues<Memory> &values) -> Loader<Memory>;

}
