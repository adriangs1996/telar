module;
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
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
  using ::gid_t;
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
  using ::getegid;
  using ::geteuid;
  using ::gethostname;
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

// errno is a macro, so importers that include no header reach it through these.
export namespace telar::sys {

  // The calling thread's errno.
  inline int lastError() noexcept {
    return errno;
  }

  // The name telar reports for an errno: a token scripts read after `error: ` and history stores
  // as a failure cause. An errno without a name gets the caller's fallback.
  inline const char* errorName(int code, const char* fallback = "Unexpected") noexcept {
    switch (code) {
    case ENOENT:
      return "FileNotFound";
    case ECONNREFUSED:
      return "ConnectionRefused";
    case EACCES:
    case EPERM:
      return "AccessDenied";
    case ENOTDIR:
      return "NotDir";
    case ENAMETOOLONG:
      return "NameTooLong";
    case ELOOP:
      return "SymLinkLoop";
    case EEXIST:
      return "PathAlreadyExists";
    case ENOSPC:
      return "NoSpaceLeft";
    case EINVAL:
      return "InvalidArgument";
    case EIO:
      return "InputOutput";
    case ENOMEM:
    case ENOBUFS:
      return "SystemResources";
    case EBADF:
      return "InvalidDescriptor";
    default:
      return fallback;
    }
  }

}
