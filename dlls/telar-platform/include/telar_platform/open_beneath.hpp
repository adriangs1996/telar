#pragma once

#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <string_view>

namespace telar::runtime {

inline FileDescriptor openBeneath(int root, std::string_view path, int flags, mode_t permissions = 0) {
  if (path.empty() || path.front() == '/' || path.size() >= PATH_MAX || path.contains('\0')) {
    throw SystemError{"Invalid package-relative path", EINVAL};
  }

  FileDescriptor parent;
  std::array<char, PATH_MAX> name;
  for (;;) {
    const auto separator = path.find('/');
    const auto component = path.substr(0, separator);
    if (component.empty() || component == "." || component == "..") {
      throw SystemError{"Invalid package-relative component", EINVAL};
    }
    std::copy(component.begin(), component.end(), name.begin());
    name[component.size()] = '\0';

    const auto selected_flags = separator == std::string_view::npos ? flags : O_RDONLY | O_DIRECTORY;
    FileDescriptor selected{::openat(parent ? parent.get() : root, name.data(), selected_flags | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC, permissions)};
    if (!selected) {
      throw SystemError{"Open package-relative file"};
    }
    if (separator == std::string_view::npos) {
      return selected;
    }

    parent = std::move(selected);
    path.remove_prefix(separator + 1);
  }
}

}
