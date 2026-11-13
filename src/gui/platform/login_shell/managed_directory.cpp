module;
#include <unistd.h>

#include <cstddef>
#include <sys/param.h>
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

module telar.gui.platform.login_shell;

import std;

import telar.gui.platform.profile_file;
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
