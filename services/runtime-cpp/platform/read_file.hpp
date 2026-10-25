#pragma once

#include "../memory/allocator.hpp"
#include "error.hpp"
#include "file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>

namespace telar::runtime {

enum class FileReadFailure {
  invalid_size,
  changed
};

class FileReadError : public std::exception {
public:
  explicit FileReadError(FileReadFailure failure) noexcept : failure_(failure) {}

  FileReadFailure failure() const noexcept { return failure_; }

  const char *what() const noexcept override {
    return failure_ == FileReadFailure::invalid_size ? "Source must be a bounded regular file" : "Source changed while reading";
  }

private:
  FileReadFailure failure_;
};

template <Allocator Memory>
String<Memory> readFileContents(Memory &memory, int descriptor, std::size_t maximum_bytes) {
  struct stat metadata{};
  if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 || static_cast<std::uint64_t>(metadata.st_size) > maximum_bytes) {
    throw FileReadError{FileReadFailure::invalid_size};
  }

  String<Memory> source{AllocatorRef<char, Memory>{memory}};
  source.resize(static_cast<std::size_t>(metadata.st_size));
  std::size_t offset = 0;
  while (offset < source.size()) {
    const auto count = ::read(descriptor, source.data() + offset, source.size() - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      throw FileReadError{FileReadFailure::changed};
    }

    offset += static_cast<std::size_t>(count);
  }

  char extra;
  ssize_t extra_count;
  do {
    extra_count = ::read(descriptor, &extra, 1);
  } while (extra_count < 0 && errno == EINTR);
  if (extra_count != 0) {
    throw FileReadError{FileReadFailure::changed};
  }

  return source;
}

template <Allocator Memory>
String<Memory> readFile(Memory &memory, const char *path, std::size_t maximum_bytes) {
  FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY)};
  if (!file) {
    throw SystemError{"Open source file"};
  }
  return readFileContents(memory, file.get(), maximum_bytes);
}

}
