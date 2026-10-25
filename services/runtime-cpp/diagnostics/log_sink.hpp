#pragma once

#include "../platform/directory_stream.hpp"
#include "log_name.hpp"
#include <algorithm>
#include <array>
#include <csignal>
#include <cstdio>
#include <limits.h>
#include <limits>
#include <sys/stat.h>

namespace telar::runtime::diagnostics {

class LogSink {
public:
  static constexpr std::size_t file_limit = 4 * 1024 * 1024;
  static constexpr std::size_t cleanup_limit = 4096;

  explicit LogSink(std::string_view endpoint, pid_t process = ::getpid(), std::size_t limit = file_limit) noexcept
      : limit_(limit) {
    if (endpoint.empty() || endpoint.front() != '/' || endpoint.contains('\0') || endpoint.size() >= PATH_MAX || process <= 0) {
      return;
    }

    const auto length = std::snprintf(path_.data(), path_.size(), "%.*s.runtime-%d.log", static_cast<int>(endpoint.size()), endpoint.data(), process);
    if (length < 0 || static_cast<std::size_t>(length) >= path_.size()) {
      return;
    }

    path_length_ = static_cast<std::size_t>(length);
    open();
  }

  bool available() const noexcept {
    return static_cast<bool>(file_);
  }

  std::string_view path() const noexcept {
    return {path_.data(), path_length_};
  }

  void disable() noexcept {
    file_.reset();
  }

  bool write(std::string_view bytes) noexcept {
    if (!file_) {
      return false;
    }

    if (written_ != 0 && (written_ > limit_ || bytes.size() > limit_ - written_)) {
      if (!rotate()) {
        disable();
        return false;
      }
    }

    while (!bytes.empty()) {
      const auto count = ::write(file_.get(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }

      if (count <= 0) {
        disable();
        return false;
      }

      written_ += static_cast<std::size_t>(count);
      bytes.remove_prefix(static_cast<std::size_t>(count));
    }

    return true;
  }

  static void removeOrphans(std::string_view endpoint) noexcept {
    const auto slash = endpoint.rfind('/');
    if (slash == std::string_view::npos || endpoint.front() != '/' || endpoint.contains('\0') || slash >= PATH_MAX) {
      return;
    }

    std::array<char, PATH_MAX> directory_path;
    const auto directory_length = std::max<std::size_t>(1, slash);
    std::copy_n(endpoint.begin(), directory_length, directory_path.begin());
    directory_path[directory_length] = '\0';

    try {
      DirectoryStream directory{FileDescriptor{::open(directory_path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      for (std::size_t scanned = 0; scanned < cleanup_limit; ++scanned) {
        const auto *entry = directory.next();
        if (entry == nullptr) {
          break;
        }

        const auto name = LogName::parse({entry->d_name, entry->d_namlen});
        if (!name || (name->endpoint != endpoint.substr(slash + 1) && !name->endpoint.ends_with(".sock"))) {
          continue;
        }

        struct stat status;
        if (::fstatat(directory.descriptor(), entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(status.st_mode)) {
          continue;
        }

        if (name->process <= static_cast<std::uint32_t>(std::numeric_limits<pid_t>::max())) {
          const auto process = static_cast<pid_t>(name->process);
          if (::kill(process, 0) == 0 || errno != ESRCH) {
            continue;
          }
        }

        ::unlinkat(directory.descriptor(), entry->d_name, 0);
      }
    } catch (...) {
    }
  }

private:
  void open() noexcept {
    file_.reset(::open(path_.data(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  }

  bool rotate() noexcept {
    std::array<char, PATH_MAX + 2> previous;
    std::copy_n(path_.begin(), path_length_, previous.begin());
    std::copy_n(".1", 3, previous.begin() + path_length_);
    file_.reset();
    if (::rename(path_.data(), previous.data()) != 0) {
      return false;
    }

    open();
    written_ = 0;
    return available();
  }

  FileDescriptor file_;
  std::array<char, PATH_MAX> path_;
  std::size_t path_length_ = 0;
  std::size_t written_ = 0;
  std::size_t limit_;
};

}
