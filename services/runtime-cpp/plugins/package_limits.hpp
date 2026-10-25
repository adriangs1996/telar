#pragma once

#include <cstddef>

namespace telar::runtime::plugins {

struct PackageLimits {
  static constexpr std::size_t configured = 32;
  static constexpr std::size_t configured_path_bytes = 512;
  static constexpr std::size_t manifest_bytes = 64 * 1024;
  static constexpr std::size_t id_bytes = 64;
  static constexpr std::size_t version_bytes = 32;
  static constexpr std::size_t entry_bytes = 256;
  static constexpr std::size_t source_bytes = 256;
  static constexpr std::size_t revision_bytes = 128;
  static constexpr std::size_t actions = 64;
  static constexpr std::size_t action_bytes = 64;
  static constexpr std::size_t grants = 64;
  static constexpr std::size_t trust_bytes = 64 * 1024;
  static constexpr std::size_t files = 256;
  static constexpr std::size_t total_bytes = 16 * 1024 * 1024;
};

}
