module;
#include <errno.h>

module telar.sys.posix;

namespace telar::sys {

  int lastError() noexcept {
    return errno;
  }

  void setLastError(int code) noexcept {
    errno = code;
  }

  const char* errorName(int code, const char* fallback) noexcept {
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
