#pragma once

#include "telar_platform/directory_stream.hpp"
#include <algorithm>
#include <array>
#include <cstdlib>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>

namespace telar::runtime {

class TemporaryDirectory {
public:
  explicit TemporaryDirectory(std::string_view pattern) {
    if (pattern.empty() || pattern.front() != '/' || !pattern.ends_with("XXXXXX") || pattern.size() >= path_.size() || pattern.contains('\0')) {
      throw SystemError{"Invalid temporary directory pattern", EINVAL};
    }

    std::copy(pattern.begin(), pattern.end(), path_.begin());
    path_[pattern.size()] = '\0';
    if (::mkdtemp(path_.data()) == nullptr) {
      throw SystemError{"Create temporary directory"};
    }
    directory_.reset(::open(path_.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (!directory_ || ::fstat(directory_.get(), &identity_) != 0 || ::fchmod(directory_.get(), 0700) != 0) {
      const auto error = errno;
      ::rmdir(path_.data());
      throw SystemError{"Open temporary directory", error};
    }
    length_ = pattern.size();
  }

  ~TemporaryDirectory() {
    removeContents(directory_.get());
    struct stat current{};
    if (::lstat(path_.data(), &current) == 0 && current.st_dev == identity_.st_dev && current.st_ino == identity_.st_ino) {
      ::rmdir(path_.data());
    }
  }

  TemporaryDirectory(const TemporaryDirectory &) = delete;
  TemporaryDirectory &operator=(const TemporaryDirectory &) = delete;

  int descriptor() const noexcept { return directory_.get(); }
  std::string_view path() const noexcept { return {path_.data(), length_}; }

private:
  static void removeContents(int directory) noexcept {
    try {
      DirectoryStream iterator{directory};
      while (const auto *entry = iterator.next()) {
        FileDescriptor child{::openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (child) {
          removeContents(child.get());
          ::unlinkat(directory, entry->d_name, AT_REMOVEDIR);
        } else {
          ::unlinkat(directory, entry->d_name, 0);
        }
      }
    } catch (...) {
    }
  }

  std::array<char, PATH_MAX> path_;
  std::size_t length_ = 0;
  FileDescriptor directory_;
  struct stat identity_{};
};

}
