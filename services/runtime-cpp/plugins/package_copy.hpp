#pragma once

#include "package_copy_storage.hpp"
#include "package_inspector.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageCopy : public PackageCopyStorage<Memory, PackageInspector> {
public:
  using PackageCopyStorage<Memory, PackageInspector>::PackageCopyStorage;
};

template <Allocator Memory>
PackageCopy(Memory &memory) -> PackageCopy<Memory>;

}
