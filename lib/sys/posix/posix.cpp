module;
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <type_traits>

module telar.sys.posix;

namespace telar::sys {

  namespace {

    // glibc's strerror_r returns the message, POSIX's writes it into the buffer and returns 0. Each
    // branch returns what the call gives, so the message borrows only the buffer it was handed.
    template <auto strerror>
    const char* textOf(int code, char* buffer, std::size_t size) noexcept {
      // strerror_r writes at most the size it is given.
#pragma clang unsafe_buffer_usage begin
      if constexpr (std::is_pointer_v<decltype(strerror(code, buffer, size))>) {
        return strerror(code, buffer, size);
      } else {
        return strerror(code, buffer, size) == 0 ? buffer : "Unknown error";
      }
#pragma clang unsafe_buffer_usage end
    }

  }

  int lastError() noexcept {
    return errno;
  }

  void setLastError(int code) noexcept {
    errno = code;
  }

  const char* errorText(int code, char* buffer, std::size_t size) noexcept {
    return textOf<::strerror_r>(code, buffer, size);
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
