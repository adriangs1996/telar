module telar.gui.foundation.system;

import std;
import telar.sys.posix;
import telar.base.ds;

namespace telar::gui::inline foundation::inline system {

  ds::Option<FileStamp> FileStamp::read(const char* path, FileSymlinks symlinks) noexcept {
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

}
