#pragma once

#include "../platform/private_directory.hpp"
#include "../platform/resolve_relative_path.hpp"
#include "../platform/write_private_file.hpp"
#include "package.hpp"
#include "trust_store.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
void updateTrust(Memory &memory, const Package &package, Capabilities capabilities, String<Memory> path) {
  auto store = TrustStore::load(memory, path);
  store.upsert(package.manifest, package.digest, capabilities);
  const auto contents = store.json(memory);

  resolveAbsolutePath(path);
  const auto separator = path.rfind('/');
  createPrivateDirectory(std::string_view{path}.substr(0, separator));
  const auto parent = openPrivateParent(path);
  const auto written = writePrivateFile(parent.get(), std::string_view{path}.substr(separator + 1), {reinterpret_cast<const std::uint8_t *>(contents.data()), contents.size()}, PrivateFileMode::replace);
  if (written != 0) {
    throw SystemError{"Replace plugin trust store", written};
  }
}

}
