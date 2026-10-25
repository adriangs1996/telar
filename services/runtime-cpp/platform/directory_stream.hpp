#pragma once

#include "error.hpp"
#include "file_descriptor.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <string_view>

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

      const std::string_view name{entry->d_name, entry->d_namlen};
      if (name != "." && name != "..") {
        return entry;
      }
    }
  }

private:
  DIR *stream_;
};

}
