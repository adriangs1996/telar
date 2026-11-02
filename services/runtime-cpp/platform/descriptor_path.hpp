#pragma once

#include "error.hpp"
#include <array>
#include <cstdio>
#include <fcntl.h>
#include <limits.h>
#include <limits>
#include <unistd.h>

namespace telar::runtime {

inline std::array<char, PATH_MAX> descriptorPath(int descriptor) {
  std::array<char, PATH_MAX> path{};
#if defined(__APPLE__)
  if (::fcntl(descriptor, F_GETPATH, path.data()) != 0) {
    throw SystemError{"Resolve open file path"};
  }
#else
  std::array<char, sizeof("/proc/self/fd/") + std::numeric_limits<int>::digits10 + 1> link{};
  std::snprintf(link.data(), link.size(), "/proc/self/fd/%d", descriptor);
  const auto length = ::readlink(link.data(), path.data(), path.size());
  if (length < 0) {
    throw SystemError{"Resolve open file path"};
  }
  if (static_cast<std::size_t>(length) >= path.size()) {
    throw SystemError{"Open file path exceeds its limit", ENAMETOOLONG};
  }
#endif
  return path;
}

}
