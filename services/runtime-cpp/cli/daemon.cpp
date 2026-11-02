#include "daemon.hpp"

namespace telar::runtime::cli {

FileDescriptor openStartLog(const char *path) noexcept {
  FileDescriptor file{::open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600)};
  struct stat state{};
  if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::getuid() || state.st_nlink != 1) {
    return FileDescriptor{};
  }
  if (::fchmod(file.get(), 0600) != 0 || ::ftruncate(file.get(), 0) != 0) {
    return FileDescriptor{};
  }

  return file;
}

pid_t spawnDaemon(const char *executable, char *const *arguments, const char *log_path) {
  auto log = openStartLog(log_path);
  FileDescriptor ignored{::open("/dev/null", O_RDWR | O_CLOEXEC)};
  if (!ignored) {
    throw SystemError{"Open daemon standard streams"};
  }

  SpawnOptions spawn{POSIX_SPAWN_SETSID};
  spawn.redirect(ignored.get(), STDIN_FILENO);
  spawn.redirect(ignored.get(), STDOUT_FILENO);
  spawn.redirect(log ? log.get() : ignored.get(), STDERR_FILENO);
  spawn.changeDirectory("/");
  spawn.closeOthers();
  pid_t child = -1;
  checkSpawn(::posix_spawn(&child, executable, &spawn.actions, &spawn.attributes, arguments, environ));
  return child;
}

}
