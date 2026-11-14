module telar.gui.platform.private_file_stamp;

import std;
import telar.sys.posix;

namespace telar::gui::platform {

  std::optional<PrivateFileStamp> PrivateFileStamp::read(const char* path) noexcept {
    struct stat status{};
    if (::lstat(path, &status) != 0) {
      return {};
    }

#ifdef __APPLE__
    const auto modified = status.st_mtimespec;
    const auto changed = status.st_ctimespec;
#else
    const auto modified = status.st_mtim;
    const auto changed = status.st_ctim;
#endif

    return PrivateFileStamp{
        .device = static_cast<std::uint64_t>(status.st_dev),
        .inode = static_cast<std::uint64_t>(status.st_ino),
        .size = static_cast<std::uint64_t>(status.st_size),
        .links = static_cast<std::uint64_t>(status.st_nlink),
        .modified_seconds = modified.tv_sec,
        .modified_nanoseconds = modified.tv_nsec,
        .changed_seconds = changed.tv_sec,
        .changed_nanoseconds = changed.tv_nsec,
        .mode = static_cast<std::uint32_t>(status.st_mode),
        .owner = static_cast<std::uint32_t>(status.st_uid),
    };
  }

}
