module;
#include <fcntl.h>
#include <linux/if_ether.h>
#include <linux/if_tun.h>
#include <netinet/tcp.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
#if !defined(__GLIBC__)
#include <linux/fs.h>
#endif

export module telar.sys.linux_api;

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
  using ::gettid;
  using ::pipe2;
  using ::posix_spawn_file_actions_addchdir_np;
  using ::syscall;
  using ::ucred;

  // The kernel's TUN device: the packet header a tunnel reads and writes.
  using ::tun_pi;
}

// glibc wraps these calls and musl does not. Only a unit that includes a libc header sees
// __GLIBC__, and importers include none, so the choice is made here: renameat2 and epoll_pwait2
// go through syscall on both (SYS_renameat2, SYS_epoll_pwait2 below), and the spawn action
// below is defined in linux.cpp.
export namespace telar::sys {

  // Adds a posix_spawn action that closes every descriptor from `lowest` up, as glibc's
  // posix_spawn_file_actions_addclosefrom_np does. ENOSYS where the libc has no such action
  // (musl): the caller closes them another way.
  int addSpawnCloseFrom(posix_spawn_file_actions_t* actions, int lowest) noexcept;

}

// Macros do not cross an import. Each one the tree reads is captured while the headers still
// define it, undefined, and exported under its own name, so `EPOLL_CTL_ADD` reads the same to an
// importer that includes the header and to one that only imports this module.
#define TELAR_SYS_CONSTANTS(X) \
  X(EPOLL_CTL_ADD)             \
  X(EPOLL_CTL_DEL)             \
  X(EPOLL_CTL_MOD)             \
  X(ETH_P_IP)                  \
  X(ETH_P_IPV6)                \
  X(IFF_TUN)                   \
  X(RENAME_NOREPLACE)          \
  X(SO_PEERCRED)               \
  X(SYS_close_range)           \
  X(SYS_epoll_pwait2)          \
  X(SYS_renameat2)             \
  X(TCP_KEEPIDLE)              \
  X(TUNSETIFF)

// glibc declares these as enumerators and defines each macro as its own name.
#define TELAR_SYS_ENUMERATORS(X) \
  X(EPOLLERR)                    \
  X(EPOLLHUP)                    \
  X(EPOLLIN)                     \
  X(EPOLLOUT)                    \
  X(EPOLLRDHUP)                  \
  X(EPOLL_CLOEXEC)               \
  X(MSG_NOSIGNAL)                \
  X(SOCK_CLOEXEC)

namespace telar::sys::captured {

#define TELAR_SYS_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_SYS_CONSTANTS(TELAR_SYS_CAPTURE)
#if !defined(__GLIBC__)
  TELAR_SYS_ENUMERATORS(TELAR_SYS_CAPTURE)
#endif

}

#undef EPOLL_CTL_ADD
#undef EPOLL_CTL_DEL
#undef EPOLL_CTL_MOD
#undef ETH_P_IP
#undef ETH_P_IPV6
#undef IFF_TUN
#undef RENAME_NOREPLACE
#undef SO_PEERCRED
#undef TCP_KEEPIDLE
#undef TUNSETIFF
#undef EPOLLERR
#undef EPOLLHUP
#undef EPOLLIN
#undef EPOLLOUT
#undef EPOLLRDHUP
#undef EPOLL_CLOEXEC
#undef MSG_NOSIGNAL
#undef SOCK_CLOEXEC
#undef SYS_close_range
#undef SYS_epoll_pwait2
#undef SYS_renameat2

#define TELAR_SYS_CONSTANT(name) inline constexpr auto name = telar::sys::captured::name##_;
#if defined(__GLIBC__)
#define TELAR_SYS_ENUMERATOR(name) using ::name;
#else
#define TELAR_SYS_ENUMERATOR TELAR_SYS_CONSTANT
#endif

export {
  TELAR_SYS_CONSTANTS(TELAR_SYS_CONSTANT)
  TELAR_SYS_ENUMERATORS(TELAR_SYS_ENUMERATOR)
}
