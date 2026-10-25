#pragma once

#include "../memory/allocator.hpp"
#include "../platform/directory_stream.hpp"
#include "package_limits.hpp"
#include <limits.h>
#include <span>
#include <sys/stat.h>

namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageFiles {
public:
  struct Entry {
    String<Memory> path;
    bool directory;
  };

  explicit PackageFiles(Memory &memory, int directory)
      : memory_(memory), entries_(AllocatorRef<Entry, Memory>{memory}) {
    String<Memory> prefix{AllocatorRef<char, Memory>{memory}};
    DirectoryStream iterator{directory};
    scan(iterator, prefix);
    std::ranges::sort(entries_, [](const auto &first, const auto &second) { return first.path < second.path; });
  }

  std::span<const Entry> entries() const noexcept { return entries_; }

private:
  void scan(DirectoryStream &iterator, String<Memory> &prefix) {
    const auto directory = iterator.descriptor();
    while (const auto *entry = iterator.next()) {
      if (entries_.size() == PackageLimits::files) {
        throw std::invalid_argument{"Too many plugin package entries"};
      }

      struct stat status{};
      if (::fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        throw SystemError{"Inspect plugin package entry"};
      }
      if (!S_ISREG(status.st_mode) && !S_ISDIR(status.st_mode)) {
        throw std::invalid_argument{"Unsupported plugin package file"};
      }

      const auto parent_length = prefix.size();
      prefix.append(entry->d_name, entry->d_namlen);
      if (prefix.size() >= PATH_MAX) {
        throw std::invalid_argument{"Plugin package path exceeds its limit"};
      }
      entries_.push_back({String<Memory>{prefix, AllocatorRef<char, Memory>{memory_}}, S_ISDIR(status.st_mode)});
      if (S_ISDIR(status.st_mode)) {
        FileDescriptor child{::openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
        if (!child) {
          throw SystemError{"Open plugin package directory"};
        }
        prefix += '/';
        DirectoryStream children{std::move(child)};
        scan(children, prefix);
      }
      prefix.resize(parent_length);
    }
  }

  Memory &memory_;
  Vector<Entry, Memory> entries_;
};

}
