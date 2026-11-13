#pragma once

#include "tbc/view.hpp"

#include "child_file.hpp"
#include "telar_platform/descriptor_path.hpp"
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

namespace telar::runtime {

  // The opened descriptor establishes which file is read. Only a canonical
  // temporary path with the protocol marker may be removed, and replacement
  // entries are checked again before cleanup. No caller-owned path is retained.
  class GraphicsTemporaryPath {
  public:
    explicit GraphicsTemporaryPath(const GraphicsChildFile& file) noexcept
        : file_(file) {}

    GraphicsTemporaryPath(const GraphicsTemporaryPath&) = delete;
    GraphicsTemporaryPath& operator=(const GraphicsTemporaryPath&) = delete;

    ~GraphicsTemporaryPath() {
      if (!armed_) {
        return;
      }

      struct stat opened{}, current{};
      if (::fstat(file_.descriptor.get(), &opened) == 0 && ::lstat(path_.data(), &current) == 0 && S_ISREG(current.st_mode) && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino && current.st_uid == ::getuid()) {
        ::unlink(path_.data());
      }
    }

    // The refusal, if any, is a literal.
    tbc::view<std::string_view, tbc::lt::static_storage> authorize() noexcept {
#if !defined(__APPLE__) && !defined(__linux__)
      return "EINVAL: unsupported medium";
#endif
      if (!descriptorPath(file_.descriptor.get(), path_)) {
        return "EINVAL: invalid data";
      }

      const std::string_view path{path_.data()};
      bool temporary = inside("/tmp", path) || inside("/dev/shm", path);

#if defined(__APPLE__)
      temporary |= inside("/private/tmp", path);
#endif
      if (!temporary) {
        const auto* environment = std::getenv("TMPDIR");
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

    const GraphicsChildFile& file_;
    std::array<char, PATH_MAX> path_{};
    bool armed_ = false;
  };

}
