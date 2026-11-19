module;
#include "tbc/annotations.hpp"

export module telar.plugins;

import std;
import telar.tbc;

import telar.base.memory.containers;
import telar.base.text.json;

import telar.platform.fs;
import telar.platform.paths;
import telar.platform.sha256;
import telar.wire.vocabulary;
import telar.base.text;
import telar.sys.posix;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: telar_plugins/action_protocol.cppm
export {
  namespace telar::runtime::plugins {

    enum class ActionTag : Byte {
      split = 1,
      focus = 2,
      sidebar = 3,
      close_pane = 4,
      new_tab = 5,
      tab_offset = 6,
      select_tab = 7,
      rename_tab = 8,
      close_tab = 9,
      move_tab = 10,
      detach = 11,
      resize = 12,
      fullscreen = 13,
      workspace_list = 14,
      new_workspace = 15,
      rename_workspace = 16,
      select_workspace = 17,
      notification = 18,
      resize_sidebar = 19,
      leave_worktree = 20,
    };

    struct ActionProtocol {
      static constexpr std::size_t maximum_effects = 16;
      static constexpr std::size_t maximum_bytes = sizeof(Byte) + (maximum_effects * (sizeof(Byte) + sizeof(NotificationLevel) + sizeof(std::uint32_t) + sizeof(NotificationTarget::Kind) + sizeof(std::uint64_t) + (sizeof(std::uint16_t) * 2) + max_notification_title_bytes + max_notification_message_bytes));
    };

  }
}

// Interface: telar_plugins/capabilities.cppm
export {
  namespace telar::runtime::plugins {

    enum class Capability : std::uint8_t {
      workspace_read,
      workspace_write,
      process_spawn,
      network,
      clipboard_read,
      clipboard_write,
      notifications,
      history_read,
      history_write,
      proxy_tap,
      runtime_control,
      traffic_observe,
      traffic_intercept,
      traffic_control,
      traffic_record,
      count,
    };

    class Capabilities {
    public:
      // Bit tests the runtime runs on every plugin traffic result and authorization check;
      // constexpr, so importers evaluate and inline them.
      constexpr bool contains(Capability capability) const noexcept {
        return (bits_ & bit(capability)) != 0;
      }

      constexpr bool containsAll(Capabilities other) const noexcept {
        return (bits_ & other.bits_) == other.bits_;
      }

      constexpr Capabilities intersection(Capabilities other) const noexcept {
        Capabilities result;

        result.bits_ = bits_ & other.bits_;
        return result;
      }

      void insert(Capability capability);
      static Capability parseName(std::string_view name);
      static std::string_view name(Capability capability) noexcept;

      template <Allocator Memory>
      static tbc::view<Capabilities, tbc::lt::a> parse(tbc::view<Memory&, tbc::lt::a> memory, const JsonValue& value);

    private:
      static constexpr std::uint16_t bit(Capability capability) noexcept {
        return std::uint16_t{1} << static_cast<unsigned>(capability);
      }

      static constexpr auto names_ = ds::Array<std::string_view, 15>{
          "workspace.read",
          "workspace.write",
          "process.spawn",
          "network",
          "clipboard.read",
          "clipboard.write",
          "notifications",
          "history.read",
          "history.write",
          "proxy.tap",
          "runtime.control",
          "traffic.observe",
          "traffic.intercept",
          "traffic.control",
          "traffic.record",
      };
      static_assert(names_.size() == static_cast<std::size_t>(Capability::count));
      static_assert(names_.size() <= 16);
      std::uint16_t bits_ = 0;
    };

    extern template Capabilities Capabilities::parse<Memory>(Memory& memory, const JsonValue& value);
    extern template Capabilities Capabilities::parse<ConcurrentMemory>(ConcurrentMemory& memory, const JsonValue& value);

  }
}

// Interface: telar_plugins/identity.cppm
export {
  namespace telar::runtime::plugins {

    using PackageDigest = ds::Array<std::uint8_t, 32>;

    constexpr std::uint64_t stableId(std::string_view name) noexcept {
      return fnv1a64(name);
    }

    bool validEntrypoint(std::string_view path) noexcept;

  }
}

// Interface: telar_plugins/package_limits.cppm
export {
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
}

// Interface: telar_plugins/schema_version.cppm
export {
}

// Interface: telar_plugins/manifest.cppm
export {
  namespace telar::runtime::plugins {

    struct Manifest {
      FixedText<PackageLimits::id_bytes> id;
      FixedText<PackageLimits::version_bytes> version;
      FixedText<PackageLimits::entry_bytes> entry;
      FixedText<PackageLimits::source_bytes> source;
      FixedText<PackageLimits::revision_bytes> revision;
      ds::Array<FixedText<PackageLimits::action_bytes>, PackageLimits::actions> actions;
      std::size_t action_count = 0;
      Capabilities capabilities;

      // The typed JSON read first, then each field's check in a fixed order,
      // failing with the manifest error names.
      template <Allocator Memory>
      static tbc::view<Manifest, tbc::lt::a> parse(tbc::view<Memory&, tbc::lt::a> memory, std::string_view bytes);

    private:
      template <Allocator Memory>
      struct Wire;

      static const char* syntaxFailure(std::string_view text) noexcept;
      static const char* fieldFailure(std::string_view message) noexcept;

      static constexpr auto field_names = ds::Array<std::string_view, 7>{"api_version", "id", "version", "entry", "source", "actions", "capabilities"};
      static constexpr auto source_names = ds::Array<std::string_view, 2>{"url", "revision"};
    };

    extern template Manifest Manifest::parse<Memory>(Memory& memory, std::string_view bytes);
    extern template Manifest Manifest::parse<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view bytes);

  }
}

// Interface: telar_plugins/package.cppm
export {
  namespace telar::runtime::plugins {

    struct Package {
      Manifest manifest;
      PackageDigest digest{};
      FixedText<PATH_MAX> root;
    };

  }
}

// Interface: telar_plugins/inspection.cppm
export {
  namespace telar::runtime::plugins {

    void appendInspection(ds::String<Memory>& output, const Package& package);

  }
}

// Interface: telar_plugins/limits.cppm
export {
  namespace telar::runtime::plugins {

    struct Limits {
      static constexpr std::size_t workers = 16;
      static constexpr std::size_t queue_depth = 64;
      static constexpr std::size_t effects = 16;
      static constexpr std::size_t effect_bytes = 64 * 1024;
      static constexpr std::size_t frame_overhead = 64 * 1024;
      static constexpr std::size_t frame_bytes = 128 * 1024 * 1024;
      static constexpr std::size_t held_bytes = 128 * 1024 * 1024;
      static constexpr std::size_t entry_bytes = 1024 * 1024;
      static constexpr std::size_t error_bytes = 4096;
      static constexpr std::size_t stderr_bytes = 4096;
      static constexpr std::size_t restarts = 5;
      static constexpr auto restart_window = std::chrono::minutes{10};
      static constexpr auto callback_deadline = std::chrono::seconds{2};
      static constexpr auto reply_deadline = std::chrono::seconds{3};
      static constexpr auto trust_check_interval = std::chrono::milliseconds{250};
      static constexpr std::size_t lua_bytes = 64 * 1024 * 1024;
      static constexpr std::uint64_t lua_instructions = 5'000'000;
    };

  }
}

// Interface: telar_plugins/package_files.cppm
export {
  namespace telar::runtime::plugins {

    template <Allocator Memory>
    class PackageFiles {
    public:
      struct Entry {
        ds::String<Memory> path;
        bool directory;
      };

      explicit PackageFiles(Memory& memory, int directory);

      std::span<const Entry> entries() const noexcept;

    private:
      void scan(DirectoryStream& iterator, ds::String<Memory>& prefix);

      Memory& memory_;
      ds::Vec<Entry, Memory> entries_;
    };

    template <Allocator Memory>
    PackageFiles(Memory& memory, int directory) -> PackageFiles<Memory>;

    extern template class PackageFiles<Memory>;
    extern template class PackageFiles<ConcurrentMemory>;

  }
}

// The copy behind PackageCopyStorage: inspect reads the copied package back with the caller's inspector.
namespace telar::runtime::plugins {

  template <Allocator Memory>
  Package copyPackage(Memory& memory, const Package& package, int destination, std::string_view path, Package (*inspect)(Memory& memory, std::string_view path));

  extern template Package copyPackage<Memory>(Memory& memory, const Package& package, int destination, std::string_view path, Package (*inspect)(Memory& memory, std::string_view path));
  extern template Package copyPackage<ConcurrentMemory>(ConcurrentMemory& memory, const Package& package, int destination, std::string_view path, Package (*inspect)(ConcurrentMemory& memory, std::string_view path));

}

// Interface: telar_plugins/package_copy_storage.cppm
export {
  namespace telar::runtime::plugins {

    // Generic over the caller's inspector, so it stays here and hands the copy to copyPackage.
    template <Allocator Memory, typename Inspector>
    class PackageCopyStorage {
    public:
      TBC_GENERIC explicit PackageCopyStorage(Memory& memory) noexcept
          : memory_(&memory) {}

      TBC_GENERIC auto copy(const Package& package, int destination, std::string_view path) -> Package {
        return copyPackage<Memory>(*memory_, package, destination, path, [](Memory& memory, std::string_view copied) {
          return Inspector::inspect(memory, copied);
        });
      }

    private:
      Memory* memory_;
    };

  }
}

// The inspection behind PackageInspection: the caller's hash behind two function pointers.
namespace telar::runtime::plugins {

  struct PackageHashing {
    void* hash;
    void (*update)(void* hash, std::string_view bytes);
    PackageDigest (*finish)(void* hash);
  };

  template <Allocator Memory>
  Package inspectConfiguredPackage(Memory& memory, std::string_view directory, std::string_view path, PackageHashing hashing);

  template <Allocator Memory>
  Package inspectPackage(Memory& memory, std::string_view path, PackageHashing hashing);

  extern template Package inspectConfiguredPackage<Memory>(Memory& memory, std::string_view directory, std::string_view path, PackageHashing hashing);
  extern template Package inspectConfiguredPackage<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view directory, std::string_view path, PackageHashing hashing);
  extern template Package inspectPackage<Memory>(Memory& memory, std::string_view path, PackageHashing hashing);
  extern template Package inspectPackage<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view path, PackageHashing hashing);

}

// Interface: telar_plugins/package_inspection.cppm
export {
  namespace telar::runtime::plugins {

    template <typename Hash>
    concept PackageHash = requires(Hash& hash, std::string_view bytes) {
      { hash.update(bytes) } -> std::same_as<void>;
      { hash.finish() } -> std::same_as<PackageDigest>;
    };

    // Generic over the caller's hash, so it stays here and hands the inspection to inspectPackage.
    template <PackageHash Hash>
    class PackageInspection {
    public:
      template <Allocator Memory>
      TBC_GENERIC static Package inspectConfigured(Memory& memory, std::string_view directory, std::string_view path) {
        Hash hash;

        return inspectConfiguredPackage(memory, directory, path, hashing(hash));
      }

      template <Allocator Memory>
      TBC_GENERIC static Package inspect(Memory& memory, std::string_view path) {
        Hash hash;

        return inspectPackage(memory, path, hashing(hash));
      }

    private:
      TBC_GENERIC static PackageHashing hashing(Hash& hash) noexcept {
        return {
            .hash = std::addressof(hash),
            .update = [](void* target, std::string_view bytes) {
              static_cast<Hash*>(target)->update(bytes);
            },
            .finish = [](void* target) -> PackageDigest {
              return static_cast<Hash*>(target)->finish();
            },
        };
      }
    };

  }
}

// Interface: telar_plugins/package_inspector.cppm
export {
  namespace telar::runtime::plugins {

    using PackageInspector = PackageInspection<Sha256>;

  }
}

// Interface: telar_plugins/package_copy.cppm
export {
  namespace telar::runtime::plugins {

    template <Allocator Memory>
    class PackageCopy : public PackageCopyStorage<Memory, PackageInspector> {
    public:
      using PackageCopyStorage<Memory, PackageInspector>::PackageCopyStorage;
    };

    template <Allocator Memory>
    PackageCopy(Memory& memory) -> PackageCopy<Memory>;

  }
}

// Interface: telar_plugins/package_installation.cppm
export {
  namespace telar::runtime::plugins {

    class PackageInstallation {
    public:
      explicit PackageInstallation(Memory& memory) noexcept;

      void install(const Package& package, std::string_view destination);

    private:
      bool existing(const Package& package, const char* path);

      static constexpr const char* staged_package = "package";
      Memory& memory_;
    };

  }
}

// Interface: telar_plugins/specifications.cppm
export {
  namespace telar::runtime::plugins {

    struct ConfiguredPlugin {
      FixedText<PackageLimits::configured_path_bytes> path;
      bool enabled = true;
    };

    struct Specifications {
      ds::Array<ConfiguredPlugin, PackageLimits::configured> entries;
      std::size_t count = 0;

      std::span<const ConfiguredPlugin> configured() const noexcept;
    };

  }
}

// The registration behind PackageRegistryStorage: inspect reads each package with the caller's inspector.
namespace telar::runtime::plugins {

  template <Allocator Memory>
  void registerPackages(ds::Vec<Package, Memory>& packages, Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications, Package (*inspect)(Memory& memory, std::string_view directory, std::string_view path));

  extern template void registerPackages<Memory>(ds::Vec<Package, Memory>& packages, Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications, Package (*inspect)(Memory& memory, std::string_view directory, std::string_view path));
  extern template void registerPackages<ConcurrentMemory>(ds::Vec<Package, ConcurrentMemory>& packages, ConcurrentMemory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications, Package (*inspect)(ConcurrentMemory& memory, std::string_view directory, std::string_view path));

}

// Interface: telar_plugins/package_registry_storage.cppm
export {
  namespace telar::runtime::plugins {

    // Generic over the caller's inspector, so it stays here and hands the registration to registerPackages.
    template <Allocator Memory, typename Inspector>
    class PackageRegistryStorage {
    public:
      TBC_GENERIC explicit PackageRegistryStorage(Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications)
          : packages_(memory) {
        registerPackages<Memory>(packages_, memory, directory, specifications, [](Memory& memory, std::string_view directory, std::string_view path) {
          return Inspector::inspectConfigured(memory, directory, path);
        });
      }

      TBC_GENERIC std::span<const Package> packages() const noexcept {
        return packages_;
      }

    private:
      ds::Vec<Package, Memory> packages_;
    };

  }
}

// Interface: telar_plugins/package_registry.cppm
export {
  namespace telar::runtime::plugins {

    template <Allocator Memory>
    class PackageRegistry : public PackageRegistryStorage<Memory, PackageInspector> {
    public:
      using PackageRegistryStorage<Memory, PackageInspector>::PackageRegistryStorage;
    };

    template <Allocator Memory>
    PackageRegistry(Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications) -> PackageRegistry<Memory>;

  }
}

// Interface: telar_plugins/paths.cppm
export {
  namespace telar::runtime::plugins {

    class Paths {
    public:
      // Generic over the caller's environment, so it stays here and hands the path to trustFile.
      template <Allocator Memory, EnvironmentLookup Environment>
      TBC_GENERIC static tbc::view<ds::String<Memory>, tbc::lt::a> trust(tbc::view<Memory&, tbc::lt::a> memory, const Environment& environment) {
        return trustFile(cli::RuntimePaths<Memory>::configHome(memory, environment));
      }

      // Generic over the caller's environment, so it stays here and hands the path to installationDirectory.
      template <Allocator Memory, EnvironmentLookup Environment>
      TBC_GENERIC static tbc::view<ds::String<Memory>, tbc::lt::a> installation(tbc::view<Memory&, tbc::lt::a> memory, const Environment& environment, const Package& package) {
        return installationDirectory(cli::xdgDirectory(memory, environment, "XDG_DATA_HOME", "/.local/share"), package);
      }

    private:
      template <Allocator Memory>
      static ds::String<Memory> trustFile(ds::String<Memory> home);

      static tbc::view<ds::String<Memory>, tbc::lt::a> installationDirectory(tbc::view<ds::String<Memory>, tbc::lt::a> data, const Package& package);
    };

    extern template ds::String<Memory> Paths::trustFile<Memory>(ds::String<Memory> home);
    extern template ds::String<ConcurrentMemory> Paths::trustFile<ConcurrentMemory>(ds::String<ConcurrentMemory> home);

  }
}

// Interface: telar_plugins/trust_store.cppm
export {
  namespace telar::runtime::plugins {

    struct TrustGrant {
      FixedText<PackageLimits::id_bytes> plugin;
      PackageDigest digest{};
      Capabilities capabilities;
    };

    class TrustStore {
    public:
      std::span<const TrustGrant> grants() const noexcept;

      template <Allocator Memory>
      static TrustStore load(Memory& memory, std::string_view path);

      template <Allocator Memory>
      static tbc::view<TrustStore, tbc::lt::a> parse(tbc::view<Memory&, tbc::lt::a> memory, std::string_view bytes);

      Capabilities granted(std::string_view id, const PackageDigest& digest) const noexcept;
      void upsert(const Manifest& manifest, const PackageDigest& digest, Capabilities capabilities);
      bool revoke(std::string_view id);

      ds::String<Memory> json(Memory& memory) const;

      static PackageDigest parseDigest(std::string_view text);

    private:
      static constexpr auto root_fields = ds::Array<std::string_view, 2>{"version", "grants"};
      static constexpr auto grant_fields = ds::Array<std::string_view, 3>{"plugin", "digest", "capabilities"};
      ds::Array<TrustGrant, PackageLimits::grants> grants_;
      std::size_t count_ = 0;
    };

    extern template TrustStore TrustStore::load<Memory>(Memory& memory, std::string_view path);
    extern template TrustStore TrustStore::load<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view path);
    extern template TrustStore TrustStore::parse<Memory>(Memory& memory, std::string_view bytes);
    extern template TrustStore TrustStore::parse<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view bytes);

  }
}

// Interface: telar_plugins/trust_update.cppm
export {
  namespace telar::runtime::plugins {

    void saveTrust(Memory& memory, const TrustStore& store, ds::String<Memory> path);

    void updateTrust(Memory& memory, const Package& package, Capabilities capabilities, ds::String<Memory> path);

    void revokeTrust(Memory& memory, std::string_view id, ds::String<Memory> path);

  }
}
