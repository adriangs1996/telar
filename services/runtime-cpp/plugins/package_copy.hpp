#pragma once

#include "../platform/write_descriptor.hpp"
#include "package_inspector.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageCopy {
public:
  explicit PackageCopy(Memory &memory) noexcept : memory_(memory) {}

  Package copy(const Package &package, int destination, std::string_view path) {
    String<Memory> source_path{package.root.view(), AllocatorRef<char, Memory>{memory_}};
    FileDescriptor source{::open(source_path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
    if (!source) {
      throw SystemError{"Open plugin package source"};
    }
    copyFiles(source.get(), destination);

    auto copied = PackageInspector::inspect(memory_, path);
    if (copied.manifest.id.view() != package.manifest.id.view() || copied.digest != package.digest) {
      throw std::invalid_argument{"Plugin changed while copying its package"};
    }
    return copied;
  }

private:
  void copyFiles(int source, int destination) {
    const PackageFiles files{memory_, source};
    std::size_t total = 0;
    for (const auto &entry : files.entries()) {
      if (entry.directory) {
        if (::mkdirat(destination, entry.path.c_str(), 0700) != 0) {
          throw SystemError{"Create plugin package directory"};
        }
        continue;
      }

      auto original = openBeneath(source, entry.path, O_RDONLY);
      const auto contents = readFileContents(memory_, original.get(), PackageLimits::total_bytes - total - 1);
      total += contents.size();
      auto copied = openBeneath(destination, entry.path, O_WRONLY | O_CREAT | O_EXCL, 0600);
      const auto error = writeDescriptor(copied.get(), {reinterpret_cast<const std::uint8_t *>(contents.data()), contents.size()});
      if (error != 0) {
        throw SystemError{"Write plugin package file", error};
      }
    }
  }

  Memory &memory_;
};

template <Allocator Memory>
PackageCopy(Memory &memory) -> PackageCopy<Memory>;

}
