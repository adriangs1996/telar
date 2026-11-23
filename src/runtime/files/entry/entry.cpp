module telar.runtime.files.entry;

import std;
import telar.sys.posix;
import telar.wire.files;

namespace telar::runtime {

  namespace {

#ifdef __APPLE__
    const timespec& modifiedTime(const struct stat& status) noexcept {
      return status.st_mtimespec;
    }
#else
    const timespec& modifiedTime(const struct stat& status) noexcept {
      return status.st_mtim;
    }
#endif

  }

  FileIdentity identityOf(const struct stat& status) noexcept {
    const auto& modified = modifiedTime(status);

    return {
        .inode = static_cast<std::uint64_t>(status.st_ino),
        .modified_seconds = static_cast<std::uint64_t>(std::max<std::int64_t>(0, modified.tv_sec)),
        .modified_nanoseconds = static_cast<std::uint32_t>(std::clamp<std::int64_t>(modified.tv_nsec, 0, FileLimits::maximum_nanoseconds)),
    };
  }

  FileKind kindOf(mode_t mode) noexcept {
    if (S_ISDIR(mode)) {
      return FileKind::directory;
    }

    if (S_ISREG(mode)) {
      return FileKind::file;
    }

    return (mode & static_cast<mode_t>(S_IFMT)) == static_cast<mode_t>(S_IFLNK) ? FileKind::link : FileKind::other;
  }

  bool names(const struct stat& status, const FileIdentity& identity) noexcept {
    return identity == FileIdentity{} || identityOf(status) == identity;
  }

}
