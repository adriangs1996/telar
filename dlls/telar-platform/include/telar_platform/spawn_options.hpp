#pragma once

#include "telar_platform/error.hpp"
#include <csignal>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
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

  // The child keeps only the standard streams and what `redirect` placed.
  // musl has no addclosefrom, so there every descriptor above stderr is
  // marked close-on-exec in this process instead: the child loses it at
  // exec, this process keeps it, and dup2 targets are fresh descriptors.
  void closeOthers() {
#if defined(__GLIBC__)
    checkSpawn(::posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1));
#elif defined(__linux__)
    DIR *descriptors = ::opendir("/proc/self/fd");
    if (descriptors == nullptr) {
      throw SystemError{"List open descriptors"};
    }

    const int own = ::dirfd(descriptors);
    while (const auto *entry = ::readdir(descriptors)) {
      char *end = nullptr;
      const auto descriptor = std::strtol(entry->d_name, &end, 10);
      if (*end == '\0' && end != entry->d_name && descriptor > STDERR_FILENO && descriptor != own) {
        const int flags = ::fcntl(static_cast<int>(descriptor), F_GETFD);
        if (flags >= 0) {
          ::fcntl(static_cast<int>(descriptor), F_SETFD, flags | FD_CLOEXEC);
        }
      }
    }

    ::closedir(descriptors);
#endif
  }

  posix_spawnattr_t attributes{};
  posix_spawn_file_actions_t actions{};
};

}
