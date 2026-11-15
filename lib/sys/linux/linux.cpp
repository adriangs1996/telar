module;
#include <errno.h>
#include <spawn.h>

module telar.sys.linux;

namespace telar::sys {

  int addSpawnCloseFrom([[maybe_unused]] posix_spawn_file_actions_t* actions, [[maybe_unused]] int lowest) noexcept {
#if defined(__GLIBC__)
    return ::posix_spawn_file_actions_addclosefrom_np(actions, lowest);
#else
    return ENOSYS;
#endif
  }

}
