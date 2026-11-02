#pragma once

#include "error.hpp"
#include <csignal>
#include <spawn.h>

namespace telar::runtime {

inline void checkSpawn(int result) {
  if (result != 0) {
    throw SystemError{"Prepare child process", result};
  }
}

class SpawnOptions {
public:
  explicit SpawnOptions(short flags) {
    checkSpawn(posix_spawnattr_init(&attributes));

    try {
      checkSpawn(posix_spawn_file_actions_init(&actions));
    } catch (...) {
      posix_spawnattr_destroy(&attributes);
      throw;
    }

    sigset_t empty;
    sigemptyset(&empty);
    sigset_t defaults;
    sigfillset(&defaults);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setpgroup(&attributes, 0);
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    checkSpawn(posix_spawnattr_setflags(&attributes, flags | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK));
  }

  ~SpawnOptions() {
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
  }

  SpawnOptions(const SpawnOptions &) = delete;
  SpawnOptions &operator=(const SpawnOptions &) = delete;

  void redirect(int source, int destination) {
    checkSpawn(posix_spawn_file_actions_adddup2(&actions, source, destination));
  }

  void changeDirectory(const char *path) {
#if defined(__APPLE__)
    checkSpawn(::posix_spawn_file_actions_addchdir(&actions, path));
#else
    checkSpawn(::posix_spawn_file_actions_addchdir_np(&actions, path));
#endif
  }

  void closeOthers() {
#if defined(__linux__)
    checkSpawn(::posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1));
#endif
  }

  posix_spawnattr_t attributes{};
  posix_spawn_file_actions_t actions{};
};

}
