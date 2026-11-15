module;
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

export module telar.sys.posix;

// The C headers stay in this global module fragment only; importers reach their
// declarations through these using-declarations instead of including them.
export {
  // Types shared by the rest of the interface.
  using ::dev_t;
  using ::gid_t;
  using ::ino_t;
  using ::iovec;
  using ::mode_t;
  using ::nfds_t;
  using ::off_t;
  using ::pid_t;
  using ::pollfd;
  using ::ssize_t;
  using ::uid_t;

  // Descriptors and their I/O.
  using ::close;
  using ::dup2;
  using ::fcntl;
  using ::flock;
  using ::fsync;
  using ::ftruncate;
  using ::ioctl;
  using ::isatty;
  using ::lseek;
  using ::open;
  using ::openat;
  using ::pipe;
  using ::poll;
  using ::pread;
  using ::read;
  using ::write;
  using ::writev;

  // Files and paths.
  using ::access;
  using ::chdir;
  using ::chmod;
  using ::faccessat;
  using ::fchdir;
  using ::fchmod;
  using ::fstat;
  using ::fstatat;
  using ::getcwd;
  using ::linkat;
  using ::lstat;
  using ::mkdir;
  using ::mkdirat;
  using ::mkdtemp;
  using ::readlink;
  using ::readlinkat;
  using ::realpath;
  using ::rename;
  using ::renameat;
  using ::rmdir;
  using ::stat;
  using ::symlink;
  using ::unlink;
  using ::unlinkat;

  // Directories.
  using ::closedir;
  using ::DIR;
  using ::dirent;
  using ::dirfd;
  using ::fdopendir;
  using ::opendir;
  using ::readdir;

  // Memory mappings and shared memory objects.
  using ::mmap;
  using ::mprotect;
  using ::munmap;
  using ::shm_open;
  using ::shm_unlink;

  // Identity, environment and system limits.
  using ::getdtablesize;
  using ::getegid;
  using ::geteuid;
  using ::gethostname;
  using ::getpagesize;
  using ::getpid;
  using ::getpwuid;
  using ::getuid;
  using ::passwd;
  using ::setenv;
  using ::strnlen;
  using ::sysconf;

  // Clocks and calendar time.
  using ::clock_gettime;
  using ::clockid_t;
  using ::gmtime_r;
  using ::localtime_r;
  using ::timespec;

  // Dynamic loading.
  using ::dlclose;
  using ::dlopen;
  using ::dlsym;
}

// Macros do not cross an import. Each one the tree reads is captured while the headers still
// define it, undefined, and exported under its own name, so `O_CLOEXEC` reads the same to an
// importer that includes the header and to one that only imports this module.
#define TELAR_SYS_ERRNOS(X) \
  X(EACCES)                 \
  X(EADDRINUSE)             \
  X(EADDRNOTAVAIL)          \
  X(EAFNOSUPPORT)           \
  X(EAGAIN)                 \
  X(EBADF)                  \
  X(EBUSY)                  \
  X(ECANCELED)              \
  X(ECHILD)                 \
  X(ECONNREFUSED)           \
  X(ECONNRESET)             \
  X(EEXIST)                 \
  X(EFBIG)                  \
  X(EINPROGRESS)            \
  X(EINTR)                  \
  X(EINVAL)                 \
  X(EIO)                    \
  X(EISDIR)                 \
  X(ELOOP)                  \
  X(EMFILE)                 \
  X(ENAMETOOLONG)           \
  X(ENETUNREACH)            \
  X(ENFILE)                 \
  X(ENOBUFS)                \
  X(ENODEV)                 \
  X(ENOENT)                 \
  X(ENOMEM)                 \
  X(ENOSPC)                 \
  X(ENOSYS)                 \
  X(ENOTDIR)                \
  X(ENOTSUP)                \
  X(ENXIO)                  \
  X(EOVERFLOW)              \
  X(EPERM)                  \
  X(EPIPE)                  \
  X(ESRCH)                  \
  X(ETIMEDOUT)              \
  X(EWOULDBLOCK)

// open, fcntl, flock and the *at calls.
#define TELAR_SYS_FILE_FLAGS(X) \
  X(AT_FDCWD)                   \
  X(AT_REMOVEDIR)               \
  X(AT_SYMLINK_NOFOLLOW)        \
  X(FD_CLOEXEC)                 \
  X(F_DUPFD_CLOEXEC)            \
  X(F_GETFD)                    \
  X(F_GETFL)                    \
  X(F_SETFD)                    \
  X(F_SETFL)                    \
  X(LOCK_EX)                    \
  X(LOCK_NB)                    \
  X(O_APPEND)                   \
  X(O_CLOEXEC)                  \
  X(O_CREAT)                    \
  X(O_DIRECTORY)                \
  X(O_EXCL)                     \
  X(O_NOCTTY)                   \
  X(O_NOFOLLOW)                 \
  X(O_NONBLOCK)                 \
  X(O_RDONLY)                   \
  X(O_RDWR)                     \
  X(O_WRONLY)

// File modes, access checks, seeks, mappings, polls and the standard descriptors.
#define TELAR_SYS_FILE_CONSTANTS(X) \
  X(F_OK)                           \
  X(POLLERR)                        \
  X(POLLHUP)                        \
  X(POLLIN)                         \
  X(POLLNVAL)                       \
  X(POLLOUT)                        \
  X(PROT_READ)                      \
  X(PROT_WRITE)                     \
  X(R_OK)                           \
  X(SEEK_SET)                       \
  X(STDERR_FILENO)                  \
  X(STDIN_FILENO)                   \
  X(STDOUT_FILENO)                  \
  X(S_IFCHR)                        \
  X(S_IFDIR)                        \
  X(S_IFLNK)                        \
  X(S_IFMT)                         \
  X(S_IFREG)                        \
  X(S_IRUSR)                        \
  X(S_IRWXU)                        \
  X(S_IWUSR)                        \
  X(S_IXUSR)                        \
  X(X_OK)

// System limits, clocks and dynamic loading.
#define TELAR_SYS_LIMITS(X) \
  X(CLOCKS_PER_SEC)         \
  X(CLOCK_MONOTONIC)        \
  X(CLOCK_REALTIME)         \
  X(NAME_MAX)               \
  X(PATH_MAX)               \
  X(PIPE_BUF)               \
  X(RTLD_LOCAL)             \
  X(RTLD_NOW)

// glibc declares these as enumerators and defines each macro as its own name.
#define TELAR_SYS_ENUMERATORS(X) \
  X(DT_DIR)                      \
  X(DT_REG)                      \
  X(_SC_CLK_TCK)                 \
  X(_SC_NPROCESSORS_ONLN)        \
  X(_SC_PAGESIZE)

namespace telar::sys::captured {

#define TELAR_SYS_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_SYS_ERRNOS(TELAR_SYS_CAPTURE)
  TELAR_SYS_FILE_FLAGS(TELAR_SYS_CAPTURE)
  TELAR_SYS_FILE_CONSTANTS(TELAR_SYS_CAPTURE)
  TELAR_SYS_LIMITS(TELAR_SYS_CAPTURE)
#if !defined(__GLIBC__)
  TELAR_SYS_ENUMERATORS(TELAR_SYS_CAPTURE)
#endif

  inline constexpr bool S_ISDIR_(mode_t mode) noexcept {
    return S_ISDIR(mode);
  }

  inline constexpr bool S_ISREG_(mode_t mode) noexcept {
    return S_ISREG(mode);
  }

  inline constexpr bool S_ISSOCK_(mode_t mode) noexcept {
    return S_ISSOCK(mode);
  }

}

#undef EACCES
#undef EADDRINUSE
#undef EADDRNOTAVAIL
#undef EAFNOSUPPORT
#undef EAGAIN
#undef EBADF
#undef EBUSY
#undef ECANCELED
#undef ECHILD
#undef ECONNREFUSED
#undef ECONNRESET
#undef EEXIST
#undef EFBIG
#undef EINPROGRESS
#undef EINTR
#undef EINVAL
#undef EIO
#undef EISDIR
#undef ELOOP
#undef EMFILE
#undef ENAMETOOLONG
#undef ENETUNREACH
#undef ENFILE
#undef ENOBUFS
#undef ENODEV
#undef ENOENT
#undef ENOMEM
#undef ENOSPC
#undef ENOSYS
#undef ENOTDIR
#undef ENOTSUP
#undef ENXIO
#undef EOVERFLOW
#undef EPERM
#undef EPIPE
#undef ESRCH
#undef ETIMEDOUT
#undef EWOULDBLOCK
#undef AT_FDCWD
#undef AT_REMOVEDIR
#undef AT_SYMLINK_NOFOLLOW
#undef FD_CLOEXEC
#undef F_DUPFD_CLOEXEC
#undef F_GETFD
#undef F_GETFL
#undef F_SETFD
#undef F_SETFL
#undef LOCK_EX
#undef LOCK_NB
#undef O_APPEND
#undef O_CLOEXEC
#undef O_CREAT
#undef O_DIRECTORY
#undef O_EXCL
#undef O_NOCTTY
#undef O_NOFOLLOW
#undef O_NONBLOCK
#undef O_RDONLY
#undef O_RDWR
#undef O_WRONLY
#undef F_OK
#undef POLLERR
#undef POLLHUP
#undef POLLIN
#undef POLLNVAL
#undef POLLOUT
#undef PROT_READ
#undef PROT_WRITE
#undef R_OK
#undef SEEK_SET
#undef STDERR_FILENO
#undef STDIN_FILENO
#undef STDOUT_FILENO
#undef S_IFCHR
#undef S_IFDIR
#undef S_IFLNK
#undef S_IFMT
#undef S_IFREG
#undef S_IRUSR
#undef S_IRWXU
#undef S_IWUSR
#undef S_IXUSR
#undef X_OK
#undef CLOCKS_PER_SEC
#undef CLOCK_MONOTONIC
#undef CLOCK_REALTIME
#undef NAME_MAX
#undef PATH_MAX
#undef PIPE_BUF
#undef RTLD_LOCAL
#undef RTLD_NOW
#undef DT_DIR
#undef DT_REG
#undef _SC_CLK_TCK
#undef _SC_NPROCESSORS_ONLN
#undef _SC_PAGESIZE
#undef S_ISDIR
#undef S_ISREG
#undef S_ISSOCK
#undef stderr
#undef stdin
#undef stdout

#define TELAR_SYS_CONSTANT(name) inline constexpr auto name = telar::sys::captured::name##_;
#if defined(__GLIBC__)
#define TELAR_SYS_ENUMERATOR(name) using ::name;
#else
#define TELAR_SYS_ENUMERATOR TELAR_SYS_CONSTANT
#endif

export {
  TELAR_SYS_ERRNOS(TELAR_SYS_CONSTANT)
  TELAR_SYS_FILE_FLAGS(TELAR_SYS_CONSTANT)
  TELAR_SYS_FILE_CONSTANTS(TELAR_SYS_CONSTANT)
  TELAR_SYS_LIMITS(TELAR_SYS_CONSTANT)
  TELAR_SYS_ENUMERATORS(TELAR_SYS_ENUMERATOR)

  inline constexpr bool S_ISDIR(mode_t mode) noexcept {
    return telar::sys::captured::S_ISDIR_(mode);
  }

  inline constexpr bool S_ISREG(mode_t mode) noexcept {
    return telar::sys::captured::S_ISREG_(mode);
  }

  inline constexpr bool S_ISSOCK(mode_t mode) noexcept {
    return telar::sys::captured::S_ISSOCK_(mode);
  }

  // Darwin's stream macros name __stdinp, __stdoutp and __stderrp; glibc and musl declare the
  // streams under their own names.
#if defined(__APPLE__)
  inline FILE*& stdin = ::__stdinp;
  inline FILE*& stdout = ::__stdoutp;
  inline FILE*& stderr = ::__stderrp;
#else
  using ::stderr;
  using ::stdin;
  using ::stdout;
#endif
}

// errno is a macro, so importers that include no header reach it through these.
export namespace telar::sys {

  // The calling thread's errno.
  int lastError() noexcept;

  // Sets the calling thread's errno, for a caller that reports its failure the way a system call does.
  void setLastError(int code) noexcept;

  // The name telar reports for an errno: a token scripts read after `error: ` and history stores
  // as a failure cause. An errno without a name gets the caller's fallback.
  const char* errorName(int code, const char* fallback = "Unexpected") noexcept;

  // sys/ioctl.h's _IOW and _IOWR take the argument's type, so they cross as templates: the request
  // that passes an Argument to the kernel, and the one that also reads it back.
  template <typename Argument>
  constexpr unsigned long ioctlWrite(char group, unsigned char number) noexcept {
    return _IOW(group, number, Argument);
  }

  template <typename Argument>
  constexpr unsigned long ioctlReadWrite(char group, unsigned char number) noexcept {
    return _IOWR(group, number, Argument);
  }

}
