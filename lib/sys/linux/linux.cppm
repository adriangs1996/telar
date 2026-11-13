module;
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/epoll.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <unistd.h>

export module telar.sys.linux;

// Linux only (cmake/module_platforms.cmake). The C headers stay in this global
// module fragment only; importers reach their declarations through these
// using-declarations instead of including them.
export {
  // Event queues.
  using ::epoll_create1;
  using ::epoll_ctl;
  using ::epoll_event;
  using ::epoll_wait;

  // Linux extensions glibc and musl both declare.
  using ::getrandom;
  using ::pipe2;
  using ::posix_spawn_file_actions_addchdir_np;
  using ::syscall;
}

// musl declares none of these; its callers reach the kernel through syscall.
#if defined(__GLIBC__)
export {
  using ::epoll_pwait2;
  using ::gettid;
  using ::posix_spawn_file_actions_addclosefrom_np;
  using ::renameat2;
}
#endif
