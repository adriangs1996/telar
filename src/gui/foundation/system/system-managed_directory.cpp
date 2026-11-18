module telar.gui.foundation.system;

import std;

import telar.sys.posix;
import telar.platform.error;
import telar.platform.fs;
import telar.base.ds;

namespace telar::gui::inline foundation::inline system {

  void prepareManagedDirectory(std::string_view path) {
    if (path.empty() || path.front() != '/' || path.contains('\0') || path.size() >= PathLimits::path_bytes) {
      throw std::invalid_argument{"Invalid managed runtime directory"};
    }

    ds::Array<char, PathLimits::path_bytes> name{};

    std::ranges::copy(path, name.viewMut().begin());
    constexpr mode_t owner_only = 0700;
    if (::mkdir(name.data(), owner_only) != 0 && sys::lastError() != EEXIST) {
      throw runtime::SystemError{"Create managed runtime directory"};
    }

    runtime::createPrivateDirectory(path);
  }

}
