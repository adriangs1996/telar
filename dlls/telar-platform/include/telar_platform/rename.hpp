#pragma once

#include <cstdio>
#include <fcntl.h>

#if defined(__linux__) && !defined(__GLIBC__)
#include <linux/fs.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace telar::runtime {

enum class RenameMode { create_only, replace };

inline int renameAt(int source_directory, const char *source, int destination_directory, const char *destination, RenameMode mode) noexcept {
#if defined(__APPLE__)
  const auto flags = mode == RenameMode::create_only ? RENAME_EXCL : 0;
  return ::renameatx_np(source_directory, source, destination_directory, destination, flags);
#elif defined(__GLIBC__)
  const auto flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
  return ::renameat2(source_directory, source, destination_directory, destination, flags);
#else
  // musl declares no renameat2; the kernel call is the same.
  const unsigned flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
  return static_cast<int>(::syscall(SYS_renameat2, source_directory, source, destination_directory, destination, flags));
#endif
}

}
