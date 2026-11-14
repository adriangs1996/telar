module;
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
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
  using ::sigaddset;
  using ::sigemptyset;
  using ::sigfillset;
  using ::sigismember;
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
  using ::pthread_mutex_t;
  using ::pthread_self;
  using ::pthread_setname_np;
  using ::pthread_t;
  using ::sched_yield;
}

// Macros do not cross an import. Each one the tree reads is captured while the headers still
// define it, undefined, and exported under its own name, so `SIGTERM` reads the same to an
// importer that includes the header and to one that only imports this module.
#define TELAR_SYS_SIGNALS(X) \
  X(NSIG)                    \
  X(SA_RESTART)              \
  X(SIGCHLD)                 \
  X(SIGHUP)                  \
  X(SIGINT)                  \
  X(SIGKILL)                 \
  X(SIGPIPE)                 \
  X(SIGQUIT)                 \
  X(SIGSTOP)                 \
  X(SIGTERM)                 \
  X(SIG_BLOCK)               \
  X(SIG_SETMASK)

// waitpid and posix_spawn.
#define TELAR_SYS_SPAWN(X)  \
  X(POSIX_SPAWN_SETPGROUP)  \
  X(POSIX_SPAWN_SETSID)     \
  X(POSIX_SPAWN_SETSIGDEF)  \
  X(POSIX_SPAWN_SETSIGMASK) \
  X(WNOHANG)

// Terminal modes and the terminal ioctls.
#define TELAR_SYS_TERMINALS(X) \
  X(ECHO)                      \
  X(ICANON)                    \
  X(ISIG)                      \
  X(TCIOFLUSH)                 \
  X(TCSAFLUSH)                 \
  X(TIOCGPGRP)                 \
  X(TIOCGWINSZ)                \
  X(TIOCSCTTY)                 \
  X(TIOCSWINSZ)                \
  X(VEOF)                      \
  X(VINTR)                     \
  X(VQUIT)                     \
  X(VSUSP)

// glibc declares these as enumerators and defines each macro as its own name.
#define TELAR_SYS_ENUMERATORS(X) \
  X(PTHREAD_CREATE_DETACHED)     \
  X(RLIMIT_NOFILE)

namespace telar::sys::captured {

#define TELAR_SYS_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_SYS_SIGNALS(TELAR_SYS_CAPTURE)
  TELAR_SYS_SPAWN(TELAR_SYS_CAPTURE)
  TELAR_SYS_TERMINALS(TELAR_SYS_CAPTURE)
#if !defined(__GLIBC__)
  TELAR_SYS_ENUMERATORS(TELAR_SYS_CAPTURE)
#endif

  inline constexpr pthread_mutex_t PTHREAD_MUTEX_INITIALIZER_ = PTHREAD_MUTEX_INITIALIZER;

  // The handlers other than SIG_DFL are integers cast to function pointers, which no constant
  // expression can hold.
  inline constexpr auto SIG_DFL_ = SIG_DFL;
  inline const auto SIG_ERR_ = SIG_ERR;
  inline const auto SIG_IGN_ = SIG_IGN;

  // Darwin reads the status through its address, which no constant expression allows.
  inline bool WIFEXITED_(int status) noexcept {
    return WIFEXITED(status);
  }

  inline int WEXITSTATUS_(int status) noexcept {
    return WEXITSTATUS(status);
  }

  inline int WTERMSIG_(int status) noexcept {
    return WTERMSIG(status);
  }

}

#undef NSIG
#undef SA_RESTART
#undef SIGCHLD
#undef SIGHUP
#undef SIGINT
#undef SIGKILL
#undef SIGPIPE
#undef SIGQUIT
#undef SIGSTOP
#undef SIGTERM
#undef SIG_BLOCK
#undef SIG_SETMASK
#undef POSIX_SPAWN_SETPGROUP
#undef POSIX_SPAWN_SETSID
#undef POSIX_SPAWN_SETSIGDEF
#undef POSIX_SPAWN_SETSIGMASK
#undef WNOHANG
#undef ECHO
#undef ICANON
#undef ISIG
#undef TCIOFLUSH
#undef TCSAFLUSH
#undef TIOCGPGRP
#undef TIOCGWINSZ
#undef TIOCSCTTY
#undef TIOCSWINSZ
#undef VEOF
#undef VINTR
#undef VQUIT
#undef VSUSP
#undef PTHREAD_CREATE_DETACHED
#undef RLIMIT_NOFILE
#undef PTHREAD_MUTEX_INITIALIZER
#undef SIG_DFL
#undef SIG_ERR
#undef SIG_IGN
#undef WIFEXITED
#undef WEXITSTATUS
#undef WTERMSIG

#define TELAR_SYS_CONSTANT(name) inline constexpr auto name = telar::sys::captured::name##_;
#if defined(__GLIBC__)
#define TELAR_SYS_ENUMERATOR(name) using ::name;
#else
#define TELAR_SYS_ENUMERATOR TELAR_SYS_CONSTANT
#endif

export {
  TELAR_SYS_SIGNALS(TELAR_SYS_CONSTANT)
  TELAR_SYS_SPAWN(TELAR_SYS_CONSTANT)
  TELAR_SYS_TERMINALS(TELAR_SYS_CONSTANT)
  TELAR_SYS_ENUMERATORS(TELAR_SYS_ENUMERATOR)

  inline constexpr pthread_mutex_t PTHREAD_MUTEX_INITIALIZER = telar::sys::captured::PTHREAD_MUTEX_INITIALIZER_;
  inline constexpr auto SIG_DFL = telar::sys::captured::SIG_DFL_;
  inline const auto SIG_ERR = telar::sys::captured::SIG_ERR_;
  inline const auto SIG_IGN = telar::sys::captured::SIG_IGN_;

  inline bool WIFEXITED(int status) noexcept {
    return telar::sys::captured::WIFEXITED_(status);
  }

  inline int WEXITSTATUS(int status) noexcept {
    return telar::sys::captured::WEXITSTATUS_(status);
  }

  inline int WTERMSIG(int status) noexcept {
    return telar::sys::captured::WTERMSIG_(status);
  }
}

// Members that the headers reach through a macro have no name an importer can spell.
export namespace telar::sys {

  // The handler a sigaction installs, the member each libc wraps in a union behind sa_handler.
  inline auto& signalHandler(struct sigaction& action) noexcept {
    return action.sa_handler;
  }

}
