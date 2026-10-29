#pragma once

#include "child_file.hpp"
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

namespace telar::runtime {

// The opened descriptor establishes which file is read. Only a canonical
// temporary path with the protocol marker may be removed, and replacement
// entries are checked again before cleanup. No caller-owned path is retained.
class GraphicsTemporaryPath {
public:
  explicit GraphicsTemporaryPath(const GraphicsChildFile &file) noexcept : file_(file) {}
  GraphicsTemporaryPath(const GraphicsTemporaryPath &) = delete;
  GraphicsTemporaryPath &operator=(const GraphicsTemporaryPath &) = delete;

  ~GraphicsTemporaryPath() {
    if (!armed_) {
      return;
    }
    struct stat opened{}, current{};
    if (::fstat(file_.descriptor.get(), &opened) == 0 && ::lstat(path_.data(), &current) == 0 && S_ISREG(current.st_mode) && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino && current.st_uid == ::getuid()) {
      ::unlink(path_.data());
    }
  }

  std::string_view authorize() noexcept {
#if defined(__APPLE__)
    if (::fcntl(file_.descriptor.get(), F_GETPATH, path_.data()) != 0) {
      return "EINVAL: invalid data";
    }
#elif defined(__linux__)
    std::array<char, 64> link;
    const auto count = std::snprintf(link.data(), link.size(), "/proc/self/fd/%d", file_.descriptor.get());
    if (count <= 0 || static_cast<std::size_t>(count) >= link.size()) {
      return "EINVAL: invalid data";
    }
    const auto length = ::readlink(link.data(), path_.data(), path_.size() - 1);
    if (length <= 0 || static_cast<std::size_t>(length) == path_.size() - 1) {
      return "EINVAL: invalid data";
    }
    path_[length] = 0;
#else
    return "EINVAL: unsupported medium";
#endif
    const std::string_view path{path_.data()};
    bool temporary = inside("/tmp", path) || inside("/dev/shm", path);
#if defined(__APPLE__)
    temporary |= inside("/private/tmp", path);
#endif
    if (!temporary) {
      const auto *environment = std::getenv("TMPDIR");
      if (environment != nullptr && ::strnlen(environment, PATH_MAX + 1) <= PATH_MAX) {
        std::array<char, PATH_MAX + 1> canonical;
        if (::realpath(environment, canonical.data()) != nullptr) {
          temporary = inside(canonical.data(), path);
        }
      }
    }
    if (!temporary) {
      return "EINVAL: temporary file not in temp dir";
    }
    if (!path.contains("tty-graphics-protocol")) {
      return "EINVAL: temporary file not named correctly";
    }
    armed_ = true;
    return {};
  }

private:
  static bool inside(std::string_view directory, std::string_view path) noexcept {
    while (directory.size() > 1 && directory.back() == '/') {
      directory.remove_suffix(1);
    }
    return path.starts_with(directory) && path.size() > directory.size() && path[directory.size()] == '/';
  }

  const GraphicsChildFile &file_;
  std::array<char, PATH_MAX + 1> path_{};
  bool armed_ = false;
};

}
