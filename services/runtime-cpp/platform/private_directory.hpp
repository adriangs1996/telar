#pragma once

#include "error.hpp"
#include "file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>

namespace telar::runtime {

inline void createPrivateDirectory(std::string_view path) {
  if (path.empty() || path.front() != '/' || path.size() >= PATH_MAX || path.find('\0') != std::string_view::npos) {
    throw SystemError{"Invalid absolute private directory", EINVAL};
  }

  std::array<char, PATH_MAX> name{};
  std::copy(path.begin(), path.end(), name.begin());
  for (std::size_t index = 1; index <= path.size(); ++index) {
    if (index != path.size() && name[index] != '/') {
      continue;
    }

    const auto separator = name[index];
    name[index] = '\0';
    if (::mkdir(name.data(), 0700) != 0 && errno != EEXIST) {
      throw SystemError{"Create private directory"};
    }
    name[index] = separator;
  }

  FileDescriptor directory{::open(name.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
  struct stat state{};
  if (!directory || ::fstat(directory.get(), &state) != 0) {
    throw SystemError{"Open private directory"};
  }
  if (state.st_uid != ::geteuid()) {
    throw SystemError{"Private directory belongs to another user", EACCES};
  }
  if (::fchmod(directory.get(), 0700) != 0) {
    throw SystemError{"Restrict private directory permissions"};
  }
}

inline FileDescriptor openPrivateParent(std::string_view file_path) {
  const auto separator = file_path.rfind('/');
  if (file_path.empty() || file_path.front() != '/' || file_path.size() >= PATH_MAX || separator == file_path.size() - 1 || file_path.find('\0') != std::string_view::npos) {
    throw SystemError{"invalid absolute runtime file path", EINVAL};
  }

  std::array<char, PATH_MAX> directory{};
  std::copy_n(file_path.data(), std::max<std::size_t>(separator, 1), directory.data());
  FileDescriptor parent{::open(directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
  struct stat state{};
  if (!parent || ::fstat(parent.get(), &state) != 0) {
    throw SystemError{"open runtime file directory"};
  }

  if (state.st_uid != ::geteuid() || (state.st_mode & 0022) != 0) {
    throw SystemError{"runtime directory must be owned by the user and not writable by others", EACCES};
  }

  return parent;
}

}
