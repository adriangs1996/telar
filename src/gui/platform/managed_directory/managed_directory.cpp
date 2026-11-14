module;
#include <unistd.h>

#include <cerrno>
#include <cstddef>
#include <fcntl.h>
#include <limits.h>
#include <sys/param.h>
#include <sys/stat.h>

module telar.gui.platform.managed_directory;

import std;

import telar.gui.platform.path_limits;
import telar.platform;
import telar.platform.primitives;

namespace telar::gui::platform {

  void prepareManagedDirectory(std::string_view path) {
    if (path.empty() || path.front() != '/' || path.contains('\0') || path.size() >= PathLimits::path_bytes) {
      throw std::invalid_argument{"Invalid managed runtime directory"};
    }

    std::array<char, PathLimits::path_bytes> name{};

    std::ranges::copy(path, name.begin());
    constexpr mode_t owner_only = 0700;
    if (::mkdir(name.data(), owner_only) != 0 && errno != EEXIST) {
      throw runtime::SystemError{"Create managed runtime directory"};
    }

    runtime::createPrivateDirectory(path);
  }

}
