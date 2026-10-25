#pragma once

#include "file_descriptor.hpp"
#include <array>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <optional>
#include <span>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace telar::runtime {

inline std::optional<std::string_view> readRegularFile(std::string_view path, std::span<char> buffer) noexcept {
  std::array<char, PATH_MAX> terminated;
  if (path.size() >= terminated.size() || path.contains('\0')) {
    return std::nullopt;
  }

  std::memcpy(terminated.data(), path.data(), path.size());
  terminated[path.size()] = '\0';
  FileDescriptor file{::open(terminated.data(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)};
  struct stat status{};
  if (!file || ::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode)) {
    return std::nullopt;
  }

  std::size_t length = 0;
  while (length < buffer.size()) {
    const auto count = ::read(file.get(), buffer.data() + length, buffer.size() - length);
    if (count > 0) {
      length += static_cast<std::size_t>(count);
    } else if (count == 0) {
      break;
    } else if (errno != EINTR) {
      return std::nullopt;
    }
  }

  return std::string_view{buffer.data(), length};
}

}
