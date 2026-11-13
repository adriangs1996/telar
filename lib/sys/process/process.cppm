module;
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

export module telar.sys.process;

// The C headers stay in this global module fragment only; importers reach their
// declarations through these using-declarations instead of including them.
export {
  // Processes and process groups.
  using ::_exit;
  using ::execv;
  using ::execve;
  using ::execvp;
  using ::fork;
  using ::getpgid;
  using ::getpgrp;
  using ::pid_t;
  using ::setsid;
  using ::waitpid;

  // Signals.
  using ::kill;
  using ::pthread_sigmask;
  using ::raise;
  using ::sigaction;
  using ::sigemptyset;
  using ::signal;
  using ::sigpending;
  using ::sigset_t;
  using ::sigwait;

  // posix_spawn.
  using ::posix_spawn;
  using ::posix_spawn_file_actions_addclose;
  using ::posix_spawn_file_actions_adddup2;
  using ::posix_spawn_file_actions_addopen;
  using ::posix_spawn_file_actions_destroy;
  using ::posix_spawn_file_actions_init;
  using ::posix_spawn_file_actions_t;
  using ::posix_spawnattr_destroy;
  using ::posix_spawnattr_init;
  using ::posix_spawnattr_setflags;
  using ::posix_spawnattr_setpgroup;
  using ::posix_spawnattr_setsigdefault;
  using ::posix_spawnattr_setsigmask;
  using ::posix_spawnattr_t;
  using ::posix_spawnp;

  // Resource limits.
  using ::getrlimit;
  using ::rlim_t;
  using ::rlimit;
  using ::setrlimit;

  // Terminals and pseudo-terminals.
  using ::cfmakeraw;
  using ::openpty;
  using ::tcflush;
  using ::tcgetattr;
  using ::tcgetpgrp;
  using ::tcsetattr;
  using ::termios;
  using ::winsize;

  // Threads.
  using ::pthread_attr_destroy;
  using ::pthread_attr_init;
  using ::pthread_attr_setdetachstate;
  using ::pthread_attr_setstacksize;
  using ::pthread_attr_t;
  using ::pthread_create;
  using ::pthread_detach;
  using ::pthread_self;
  using ::pthread_setname_np;
  using ::pthread_t;
  using ::sched_yield;
}
