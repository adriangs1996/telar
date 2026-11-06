module;

#include <string_view>
#include <cstddef>
#include <sys/param.h>
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <stdexcept>

module telar.gui.platform.login_shell;

import telar.gui.platform.profile_file;
import telar.platform;


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
