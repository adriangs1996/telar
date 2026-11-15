module telar.gui.platform.managed_directory;

import std;
import telar.sys.posix;

import telar.gui.platform.path_limits;
import telar.platform.error;
import telar.platform.fs;

namespace telar::gui::platform {

  void prepareManagedDirectory(std::string_view path) {
    if (path.empty() || path.front() != '/' || path.contains('\0') || path.size() >= PathLimits::path_bytes) {
      throw std::invalid_argument{"Invalid managed runtime directory"};
    }

    std::array<char, PathLimits::path_bytes> name{};

    std::ranges::copy(path, name.begin());
    constexpr mode_t owner_only = 0700;
    if (::mkdir(name.data(), owner_only) != 0 && sys::lastError() != EEXIST) {
      throw runtime::SystemError{"Create managed runtime directory"};
    }

    runtime::createPrivateDirectory(path);
  }

}
