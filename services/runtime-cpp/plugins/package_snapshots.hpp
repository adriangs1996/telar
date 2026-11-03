#pragma once

#include "telar_platform/temporary_directory.hpp"
#include "telar_plugins/package_copy.hpp"
#include <charconv>
#include <optional>

namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageSnapshots {
public:
  explicit PackageSnapshots(Memory &memory) noexcept : memory_(memory) {}

  Package copy(const Package &package, std::size_t index) {
    if (!directory_) {
      directory_.emplace("/tmp/telar-tap-workers-XXXXXX");
    }

    std::array<char, 32> name;
    constexpr std::string_view prefix = "package-";
    std::copy(prefix.begin(), prefix.end(), name.begin());
    const auto suffix = std::to_chars(name.data() + prefix.size(), name.data() + name.size() - 1, index);
    if (suffix.ec != std::errc{}) {
      throw std::length_error{"Plugin package index exceeds its limit"};
    }
    *suffix.ptr = '\0';
    if (::mkdirat(directory_->descriptor(), name.data(), 0700) != 0) {
      throw SystemError{"Create plugin snapshot"};
    }

    auto target = openBeneath(directory_->descriptor(), name.data(), O_RDONLY | O_DIRECTORY);
    String<Memory> destination{directory_->path(), AllocatorRef<char, Memory>{memory_}};
    destination += '/';
    destination += name.data();
    return PackageCopy{memory_}.copy(package, target.get(), destination);
  }

  std::string_view path() const noexcept { return directory_ ? directory_->path() : std::string_view{}; }

private:
  Memory &memory_;
  std::optional<TemporaryDirectory> directory_;
};

}
