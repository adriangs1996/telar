#pragma once

#include "package_inspector.hpp"
#include "package_registry_storage.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageRegistry : public PackageRegistryStorage<Memory, PackageInspector> {
public:
  using PackageRegistryStorage<Memory, PackageInspector>::PackageRegistryStorage;
};

template <Allocator Memory>
PackageRegistry(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications) -> PackageRegistry<Memory>;

}
