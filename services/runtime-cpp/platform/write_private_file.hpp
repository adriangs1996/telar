#pragma once

#include "file_descriptor.hpp"
#include "write_descriptor.hpp"
#include "rename.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <string_view>

namespace telar::runtime {

using PrivateFileMode = RenameMode;

inline int writePrivateFile(int directory, std::string_view name, std::span<const std::uint8_t> bytes, PrivateFileMode mode) noexcept {
  if (name.empty() || name.size() > NAME_MAX || name.contains('\0') || name.contains('/') || name == "." || name == "..") {
    return EINVAL;
  }

  std::array<char, NAME_MAX + 1> destination;
  std::copy(name.begin(), name.end(), destination.begin());
  destination[name.size()] = '\0';
  constexpr unsigned maximum_attempts = 8;
  for (unsigned attempt = 0; attempt < maximum_attempts; ++attempt) {
    std::uint64_t nonce;
    ::arc4random_buf(&nonce, sizeof(nonce));
    std::array<char, 64> temporary;
    std::snprintf(temporary.data(), temporary.size(), ".telar-write-%016llx.tmp", static_cast<unsigned long long>(nonce));
    FileDescriptor file{::openat(directory, temporary.data(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)};
    if (!file) {
      if (errno == EEXIST) {
        continue;
      }
      return errno;
    }

    const int written = writeDescriptor(file.get(), bytes);
    if (written != 0 || ::fsync(file.get()) != 0) {
      const int failure = written != 0 ? written : errno;
      file.reset();
      ::unlinkat(directory, temporary.data(), 0);
      return failure;
    }
    file.reset();

    if (renameAt(directory, temporary.data(), directory, destination.data(), mode) != 0) {
      const int failure = errno;
      ::unlinkat(directory, temporary.data(), 0);
      return failure;
    }
    return 0;
  }
  return EEXIST;
}

}
