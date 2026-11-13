#pragma once

#include <array>
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdio>
#include <fcntl.h>
#include <limits>
#include <unistd.h>

namespace telar::runtime {

  // The path the open file `descriptor` has now, written terminated into `path`; false, with errno
  // set, when the system cannot tell or the path does not fit.
  inline bool descriptorPath(int descriptor, std::array<char, PATH_MAX>& path) noexcept {
#if defined(__APPLE__)
    return ::fcntl(descriptor, F_GETPATH, path.data()) == 0;
#elif defined(__linux__)
    std::array<char, sizeof("/proc/self/fd/") + std::numeric_limits<int>::digits10 + 1> link{};
    std::snprintf(link.data(), link.size(), "/proc/self/fd/%d", descriptor);
    const auto length = ::readlink(link.data(), path.data(), path.size());
    if (length <= 0) {
      return false;
    }
    if (static_cast<std::size_t>(length) >= path.size()) {
      errno = ENAMETOOLONG;
      return false;
    }
    path[static_cast<std::size_t>(length)] = '\0';
    return true;
#else
    static_cast<void>(descriptor);
    static_cast<void>(path);
    errno = ENOTSUP;
    return false;
#endif
  }

}
