#pragma once

#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <dirent.h>
#include <fcntl.h>

namespace telar::runtime {

class DirectoryStream {
public:
  explicit DirectoryStream(int directory)
      : DirectoryStream(FileDescriptor{::openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)}) {}

  explicit DirectoryStream(FileDescriptor iterator) {
    if (!iterator) {
      throw SystemError{"Open directory iterator"};
    }

    stream_ = ::fdopendir(iterator.get());
    if (stream_ == nullptr) {
      throw SystemError{"Create directory iterator"};
    }
    iterator.release();
  }

  ~DirectoryStream() { ::closedir(stream_); }

  DirectoryStream(const DirectoryStream &) = delete;
  DirectoryStream &operator=(const DirectoryStream &) = delete;

  int descriptor() const noexcept { return ::dirfd(stream_); }

  const dirent *next() {
    for (;;) {
      errno = 0;
      const auto *entry = ::readdir(stream_);
      if (entry == nullptr) {
        if (errno != 0) {
          throw SystemError{"Read directory entry"};
        }
        return nullptr;
      }

      const auto *name = entry->d_name;
      const bool current_directory = name[0] == '.' && name[1] == '\0';
      const bool parent_directory = name[0] == '.' && name[1] == '.' && name[2] == '\0';
      if (!current_directory && !parent_directory) {
        return entry;
      }
    }
  }

private:
  DIR *stream_;
};

}
