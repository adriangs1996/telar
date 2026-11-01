#ifndef TELAR_RUNTIME_PLUGIN_PACKAGE_COPY_STORAGE_HPP
#define TELAR_RUNTIME_PLUGIN_PACKAGE_COPY_STORAGE_HPP

#include "../platform/open_beneath.hpp"
#include "../platform/file_descriptor.hpp"
#include "../platform/error.hpp"
#include "../memory/allocator.hpp"
#include "package_limits.hpp"
#include <cstddef>
#include <fcntl.h>
#include <stdexcept>
#include <string_view>
#include "../platform/open_directory.h"
#include "../platform/read_file.hpp"
#include "package.hpp"
#include "package_files.hpp"
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>

namespace telar::runtime::plugins {

template <Allocator Memory, typename Inspector>
class PackageCopyStorage {
public:
  explicit PackageCopyStorage(Memory &memory) noexcept
      : memory_(&memory) {}

  auto copy(const Package &package, int destination, std::string_view path) -> Package {
    String<Memory> source_path{package.root.view(), AllocatorRef<char, Memory>{*memory_}};
    FileDescriptor source{telarOpenDirectoryNoFollow(source_path.c_str())};
    if (!source) {
      throw SystemError{"Open plugin package source"};
    }
    copyFiles(source, destination);

    auto copied = Inspector::inspect(*memory_, path);
    if (copied.manifest.id.view() != package.manifest.id.view() || copied.digest != package.digest) {
      throw std::invalid_argument{"Plugin changed while copying its package"};
    }
    return copied;
  }

private:
  void copyFiles(const FileDescriptor &source, int destination) {
    const PackageFiles files{*memory_, source.get()};
    std::size_t total = 0;
    for (const auto &entry : files.entries()) {
      if (entry.directory) {
        if (::mkdirat(destination, entry.path.c_str(), S_IRWXU) != 0) {
          throw SystemError{"Create plugin package directory"};
        }
        continue;
      }

      auto original = openBeneath(source.get(), entry.path, O_RDONLY);
      const auto contents = readFileContents(*memory_, original.get(), PackageLimits::total_bytes - total - 1);
      total += contents.size();
      auto copied = openBeneath(destination, entry.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
      const auto error = writeFile(copied, contents);
      if (error != 0) {
        throw SystemError{"Write plugin package file", error};
      }
    }
  }

  static auto writeFile(const FileDescriptor &destination, std::string_view bytes) noexcept -> int {
    while (!bytes.empty()) {
      const auto count = ::write(destination.get(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        return count == 0 ? EIO : errno;
      }

      bytes.remove_prefix(static_cast<std::size_t>(count));
    }

    return 0;
  }

  Memory *memory_;
};

}

#endif
