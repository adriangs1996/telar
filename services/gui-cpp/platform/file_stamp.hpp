#pragma once

#include <cstdint>
#include <optional>
#include <sys/stat.h>

namespace telar::gui::platform {

enum class FileSymlinks : std::uint8_t {
  follow,
  inspect,
};

struct FileStamp {
  std::uint64_t size = 0;
  std::int64_t modified_seconds = 0;
  std::int64_t modified_nanoseconds = 0;
  std::uint32_t kind = 0;

  bool operator==(const FileStamp &) const = default;

  [[nodiscard]] static std::optional<FileStamp> read(const char *path, FileSymlinks symlinks = FileSymlinks::follow) noexcept {
    struct stat status{};
    const auto result = symlinks == FileSymlinks::follow ? ::stat(path, &status) : ::lstat(path, &status);
    if (result != 0) {
      return {};
    }

#ifdef __APPLE__
    const auto modified = status.st_mtimespec;
#else
    const auto modified = status.st_mtim;
#endif

    return FileStamp{.size = static_cast<std::uint64_t>(status.st_size), .modified_seconds = modified.tv_sec, .modified_nanoseconds = modified.tv_nsec, .kind = static_cast<std::uint32_t>(status.st_mode & S_IFMT)};
  }
};

}
