#pragma once

#include "error.hpp"
#include <array>
#include <cstdlib>
#include <limits.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif
#include <string_view>

namespace telar::runtime {

class ExecutablePath {
public:
  ExecutablePath() {
    std::array<char, PATH_MAX> original;
#if defined(__APPLE__)
    auto size = static_cast<std::uint32_t>(original.size());
    if (::_NSGetExecutablePath(original.data(), &size) != 0) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }
#else
    const auto length = ::readlink("/proc/self/exe", original.data(), original.size());
    if (length < 0) {
      throw SystemError{"Read runtime executable path"};
    }
    if (static_cast<std::size_t>(length) >= original.size()) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }
    original[length] = '\0';
#endif
    if (::realpath(original.data(), path_.data()) == nullptr) {
      throw SystemError{"Resolve runtime executable"};
    }
  }

  const char *c_str() const noexcept {
    return path_.data();
  }

  std::string_view view() const noexcept {
    return path_.data();
  }

private:
  std::array<char, PATH_MAX> path_;
};

}
