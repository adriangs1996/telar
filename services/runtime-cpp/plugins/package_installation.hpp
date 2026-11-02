#pragma once

#include "../platform/private_directory.hpp"
#include "../platform/temporary_directory.hpp"
#include "../platform/rename.hpp"
#include "package_copy.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageInstallation {
public:
  explicit PackageInstallation(Memory &memory) noexcept : memory_(memory) {}

  void install(const Package &package, std::string_view destination) {
    String<Memory> path{destination, AllocatorRef<char, Memory>{memory_}};
    resolveAbsolutePath(path);
    if (existing(package, path.c_str())) {
      return;
    }

    const auto separator = path.rfind('/');
    String<Memory> parent{std::string_view{path}.substr(0, separator), AllocatorRef<char, Memory>{memory_}};
    createPrivateDirectory(parent);
    auto directory = openPrivateParent(path);
    parent += "/.telar-plugin-XXXXXX";
    TemporaryDirectory staging{parent};
    if (::mkdirat(staging.descriptor(), staged_package, 0700) != 0) {
      throw SystemError{"Create plugin installation staging directory"};
    }
    auto copied = openBeneath(staging.descriptor(), staged_package, O_RDONLY | O_DIRECTORY);
    String<Memory> staged_path{staging.path(), AllocatorRef<char, Memory>{memory_}};
    staged_path += '/';
    staged_path += staged_package;
    PackageCopy{memory_}.copy(package, copied.get(), staged_path);

    if (renameAt(staging.descriptor(), staged_package, directory.get(), path.c_str() + separator + 1, RenameMode::create_only) != 0) {
      if (errno == EEXIST && existing(package, path.c_str())) {
        return;
      }
      throw SystemError{"Publish plugin installation"};
    }
  }

private:
  bool existing(const Package &package, const char *path) {
    struct stat state{};
    if (::lstat(path, &state) != 0) {
      if (errno == ENOENT) {
        return false;
      }
      throw SystemError{"Inspect plugin installation target"};
    }
    if (!S_ISDIR(state.st_mode)) {
      throw std::invalid_argument{"Plugin installation target is not a directory"};
    }
    const auto installed = PackageInspector::inspect(memory_, path);
    if (installed.digest != package.digest) {
      throw std::invalid_argument{"Plugin installation target has a different digest"};
    }
    return true;
  }

  static constexpr const char *staged_package = "package";
  Memory &memory_;
};

template <Allocator Memory>
PackageInstallation(Memory &memory) -> PackageInstallation<Memory>;

}
