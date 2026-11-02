#include "managed_directory.hpp"
#include "platform/error.hpp"
#include "platform/path_limits.hpp"
#include "platform/private_directory.hpp"
#include <algorithm>
#include <array>
#include <cerrno>
#include <stdexcept>
#include <string_view>
#include <sys/stat.h>

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
