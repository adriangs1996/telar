module;
#include <dirent.h>
#include <dlfcn.h>
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
