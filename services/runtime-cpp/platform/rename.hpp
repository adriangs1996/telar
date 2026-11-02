#pragma once

#include <cstdio>
#include <fcntl.h>

namespace telar::runtime {

enum class RenameMode { create_only, replace };

inline int renameAt(int source_directory, const char *source, int destination_directory, const char *destination, RenameMode mode) noexcept {
#if defined(__APPLE__)
  const auto flags = mode == RenameMode::create_only ? RENAME_EXCL : 0;
  return ::renameatx_np(source_directory, source, destination_directory, destination, flags);
#else
  const auto flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
  return ::renameat2(source_directory, source, destination_directory, destination, flags);
#endif
}

}
