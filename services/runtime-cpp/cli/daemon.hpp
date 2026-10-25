#pragma once

#include "../platform/executable_path.hpp"
#include "../platform/spawn_options.hpp"
#include "runtime_paths.hpp"
#include <sys/wait.h>

extern char **environ;

namespace telar::runtime::cli {

FileDescriptor openStartLog(const char *path) noexcept;
pid_t spawnDaemon(const char *executable, char *const *arguments, const char *log_path);

template <Allocator Memory>
pid_t launchDaemon(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths) {
  ExecutablePath executable;
  std::array<char, PATH_MAX> config_path;
  Vector<char *, Memory> arguments{AllocatorRef<char *, Memory>{memory}};
  arguments.reserve(2 * options.engine_argument_count + 28);
  const auto append = [&](std::string_view value) { arguments.push_back(const_cast<char *>(value.data())); };
  append(executable.view());
  append("server");
  append("--daemonized");
  append("--socket");
  append(paths.socket);
  if (!options.history.empty()) {
    append("--history");
    append(options.history);
  }
  if (!options.session.empty()) {
    append("--session");
    append(options.session);
  }
  if (!options.clone_session.empty()) {
    append("--clone-session");
    append(options.clone_session);
    append("--clone-from");
    append(options.clone_from);
  }
  if (!options.trace.empty()) {
    append("--trace");
    append(options.trace);
  }
  if (!options.config.empty()) {
    if (::realpath(options.config.data(), config_path.data()) == nullptr) {
      throw SystemError{"Resolve daemon configuration"};
    }

    append("--config");
    append(config_path.data());
  }
  if (!options.profile.empty()) {
    append("--profile");
    append(options.profile);
  }
  for (const auto argument : std::span{options.engine_arguments}.first(options.engine_argument_count)) {
    append("--engine-arg");
    append(argument);
  }
  for (const auto [enabled, flag] : std::array<std::pair<bool, std::string_view>, 4>{{{options.no_config, "--no-config"}, {options.fresh, "--fresh"}, {!options.persist_session, "--no-session"}, {!options.resume_agents, "--no-resume"}}}) {
    if (enabled) {
      append(flag);
    }
  }

  arguments.push_back(nullptr);
  String<Memory> log_path{paths.socket, AllocatorRef<char, Memory>{memory}};
  log_path += ".runtime.start.log";
  return spawnDaemon(executable.c_str(), arguments.data(), log_path.c_str());
}

}
