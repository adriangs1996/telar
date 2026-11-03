#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <cstdint>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

namespace telar::runtime {

template <Allocator Memory>
bool readPrivateFile(int directory, std::string_view name, Vector<unsigned char, Memory> &bytes, std::size_t limit) {
  if (name.empty() || name.size() >= PATH_MAX || name.contains('\0')) {
    throw SystemError{"Invalid private file path", EINVAL};
  }

  std::array<char, PATH_MAX> terminated;
  std::copy(name.begin(), name.end(), terminated.begin());
  terminated[name.size()] = '\0';
  FileDescriptor file{::openat(directory, terminated.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
  if (!file) {
    if (errno == ENOENT) {
      return false;
    }
    throw SystemError{"Open private file"};
  }

  struct stat state{};
  if (::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
    throw SystemError{"Validate private file", EACCES};
  }
  if (state.st_size < 0 || static_cast<std::uint64_t>(state.st_size) > limit) {
    throw SystemError{"Private file exceeds its limit", EFBIG};
  }

  bytes.resize(static_cast<std::size_t>(state.st_size));
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const auto count = ::read(file.get(), bytes.data() + offset, bytes.size() - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      throw SystemError{"Private file changed while reading", EIO};
    }
    offset += static_cast<std::size_t>(count);
  }

  unsigned char extra;
  ssize_t count;
  do {
    count = ::read(file.get(), &extra, 1);
  } while (count < 0 && errno == EINTR);
  if (count != 0) {
    throw SystemError{"Private file changed while reading", EIO};
  }
  return true;
}

}
