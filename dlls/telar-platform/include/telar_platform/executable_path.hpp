#pragma once

#include "telar_platform/error.hpp"
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

  // The executable called `name` beside this one, as installed telar programs are:
  // `telar` and `telar-runtime` share a directory, and symlinks resolve to it first.
  explicit ExecutablePath(std::string_view name)
      : ExecutablePath() {
    const std::string_view self = path_.data();
    const auto directory = self.substr(0, self.rfind('/') + 1);
    if (directory.size() + name.size() >= path_.size()) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }

    name.copy(path_.data() + directory.size(), name.size());
    path_[directory.size() + name.size()] = '\0';
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
