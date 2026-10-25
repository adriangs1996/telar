#pragma once

#include "error.hpp"
#include <array>
#include <cstdlib>
#include <limits.h>
#include <mach-o/dyld.h>
#include <string_view>

namespace telar::runtime {

class ExecutablePath {
public:
  ExecutablePath() {
    std::array<char, PATH_MAX> original;
    auto size = static_cast<std::uint32_t>(original.size());
    if (::_NSGetExecutablePath(original.data(), &size) != 0) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }
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
