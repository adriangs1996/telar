#pragma once

#include "package_inspector.hpp"
#include "specifications.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageRegistry {
public:
  explicit PackageRegistry(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications)
      : packages_(AllocatorRef<Package, Memory>{memory}) {
    for (const auto &specification : specifications) {
      if (!specification.enabled) {
        continue;
      }
      if (packages_.size() == PackageLimits::configured) {
        throw std::invalid_argument{"Too many configured plugins"};
      }

      auto package = PackageInspector::inspectConfigured(memory, directory, specification.path.view());
      for (const auto &existing : packages_) {
        if (existing.manifest.id.view() == package.manifest.id.view()) {
          throw std::invalid_argument{"Duplicate plugin ID"};
        }
        if (stableId(existing.manifest.id.view()) == stableId(package.manifest.id.view())) {
          throw std::invalid_argument{"Plugin ID hash collision"};
        }
      }
      packages_.push_back(std::move(package));
    }
  }

  std::span<const Package> packages() const noexcept { return packages_; }

private:
  Vector<Package, Memory> packages_;
};

template <Allocator Memory>
PackageRegistry(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications) -> PackageRegistry<Memory>;

}
