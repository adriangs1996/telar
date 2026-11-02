#pragma once

#include "../platform/open_beneath.hpp"
#include "../platform/read_file.hpp"
#include "../platform/resolve_relative_path.hpp"
#include "limits.hpp"
#include "package.hpp"
#include "package_files.hpp"
#include <concepts>
#include <limits>

namespace telar::runtime::plugins {

template <typename Hash>
concept PackageHash = requires(Hash &hash, std::string_view bytes) {
  { hash.update(bytes) } -> std::same_as<void>;
  { hash.finish() } -> std::same_as<PackageDigest>;
};

template <PackageHash Hash>
class PackageInspection {
public:
  template <Allocator Memory>
  static Package inspectConfigured(Memory &memory, std::string_view directory, std::string_view path) {
    String<Memory> resolved{path, AllocatorRef<char, Memory>{memory}};
    resolveRelativePath(resolved, directory);
    return inspect(memory, resolved);
  }

  template <Allocator Memory>
  static Package inspect(Memory &memory, std::string_view path) {
    if (path.empty() || path.size() >= PATH_MAX || path.contains('\0')) {
      throw std::invalid_argument{"Invalid plugin package path"};
    }

    std::array<char, PATH_MAX> terminated;
    std::copy(path.begin(), path.end(), terminated.begin());
    terminated[path.size()] = '\0';
    std::array<char, PATH_MAX> canonical;
    if (::realpath(terminated.data(), canonical.data()) == nullptr) {
      throw SystemError{"Resolve plugin package"};
    }
    FileDescriptor directory{::open(canonical.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
    if (!directory) {
      throw SystemError{"Open plugin package"};
    }

    auto manifest_file = openBeneath(directory.get(), "plugin.json", O_RDONLY);
    const auto source = readFileContents(memory, manifest_file.get(), PackageLimits::manifest_bytes - 1);
    Package package;
    package.root.assign(canonical.data());
    package.manifest = Manifest::parse(memory, source);
    auto entry = openBeneath(directory.get(), package.manifest.entry.view(), O_RDONLY);
    readFileContents(memory, entry.get(), Limits::entry_bytes - 1);
    package.digest = digest(memory, directory.get());
    return package;
  }

private:
  template <Allocator Memory>
  static PackageDigest digest(Memory &memory, int directory) {
    const PackageFiles files{memory, directory};
    Hash hash;
    static constexpr char domain[] = "telar-plugin-package-v1";
    hash.update({domain, sizeof(domain)});
    std::size_t total = 0;
    for (const auto &entry : files.entries()) {
      if (entry.directory) {
        continue;
      }
      auto file = openBeneath(directory, entry.path, O_RDONLY);
      const auto bytes = readFileContents(memory, file.get(), PackageLimits::total_bytes - total - 1);
      total += bytes.size();
      hashLength(hash, entry.path.size());
      hash.update(entry.path);
      hashLength(hash, bytes.size());
      hash.update(bytes);
    }
    return hash.finish();
  }

  static void hashLength(Hash &hash, std::uint64_t length) {
    std::array<char, sizeof(length)> encoded;
    for (std::size_t index = 0; index < encoded.size(); ++index) {
      encoded[index] = static_cast<char>(length & UINT8_MAX);
      length >>= std::numeric_limits<std::uint8_t>::digits;
    }
    hash.update({encoded.data(), encoded.size()});
  }
};

}
