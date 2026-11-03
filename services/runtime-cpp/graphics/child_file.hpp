#pragma once

#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/graphics/child_name.hpp"
#include <algorithm>
#include <array>
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <limits>
#include <sys/stat.h>

namespace telar::runtime {

struct GraphicsChildFile {
  FileDescriptor descriptor;
  std::uint64_t size;

  static std::optional<GraphicsChildFile> open(std::string_view encoded_path) noexcept {
    std::array<std::uint8_t, PATH_MAX + 1> path;
    const auto *decoded = decodeGraphicsName(encoded_path, path);
    return openPath(decoded);
  }

  static std::optional<GraphicsChildFile> openDecoded(std::span<const std::uint8_t> decoded_path) noexcept {
    std::array<std::uint8_t, PATH_MAX + 1> path;
    return openPath(copyGraphicsName(decoded_path, path));
  }

  static std::optional<GraphicsChildFile> openPath(const char *decoded) noexcept {
    if (decoded == nullptr || decoded[0] != '/') {
      return std::nullopt;
    }

    FileDescriptor file{::open(decoded, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
    struct stat metadata{};
    if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != ::getuid() || metadata.st_size < 0) {
      return std::nullopt;
    }
    return GraphicsChildFile{std::move(file), static_cast<std::uint64_t>(metadata.st_size)};
  }

  bool read(std::span<std::uint8_t> bytes, std::uint64_t offset) const noexcept {
    std::size_t filled = 0;
    while (filled < bytes.size()) {
      if (offset > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max()) - filled) {
        return false;
      }

      const auto count = ::pread(descriptor.get(), bytes.data() + filled, bytes.size() - filled, static_cast<off_t>(offset + filled));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        return false;
      }
      filled += static_cast<std::size_t>(count);
    }
    return true;
  }
};

}
