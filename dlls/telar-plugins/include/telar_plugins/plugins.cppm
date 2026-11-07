module;
#include <cstring>
#include <memory>
#include <type_traits>
#include <string>
#include <variant>
#include <vector>
#include <bit>
#include <utility>
#include <mutex>
#include <new>
#include <stdlib.h>

#include <cstddef>
#include <cstdint>

#include <exception>
#include <charconv>
#include <optional>
#include <span>
#include <string_view>
#include <array>

#include <algorithm>

#include <stdexcept>

#include <limits.h>

#include <chrono>

#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>

#include "telar_platform/open_directory.h"
#include <unistd.h>

#include <concepts>
#include <limits>

#include <openssl/sha.h>

#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <cstdlib>

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

export module telar.plugins;

export import telar.base.text;


export import telar.platform;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

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
  count
};

class Capabilities {
public:
  inline bool contains(Capability capability) const noexcept {
    return (bits_ & bit(capability)) != 0;
  }

  inline bool containsAll(Capabilities other) const noexcept { return (bits_ & other.bits_) == other.bits_; }

  inline Capabilities intersection(Capabilities other) const noexcept {
    Capabilities result;
    result.bits_ = bits_ & other.bits_;
    return result;
  }

  inline void insert(Capability capability) {
    if (contains(capability)) {
      throw std::invalid_argument{"DuplicateCapability"};
    }
    bits_ |= bit(capability);
  }

  inline static Capability parseName(std::string_view name) {
    const auto found = std::ranges::find(names_, name);
    if (found == names_.end()) {
      throw std::invalid_argument{"UnknownCapability"};
    }
    return static_cast<Capability>(found - names_.begin());
  }

  inline static std::string_view name(Capability capability) noexcept {
    return names_[static_cast<std::size_t>(capability)];
  }

  template <Allocator Memory>
  inline static Capabilities parse(Memory &memory, const JsonValue &value) {
    Capabilities result;
    String<Memory> text{AllocatorRef<char, Memory>{memory}};
    value.eachElement([&](const JsonValue &element) {
      element.string(text);
      result.insert(parseName(text));
    });
    return result;
  }

private:
  static constexpr std::uint16_t bit(Capability capability) noexcept {
    return std::uint16_t{1} << static_cast<unsigned>(capability);
  }

  static constexpr auto names_ = std::to_array<std::string_view>({
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
  });
  static_assert(names_.size() == static_cast<std::size_t>(Capability::count));
  static_assert(names_.size() <= 16);
  std::uint16_t bits_ = 0;
};

}
}

// Interface: telar_plugins/identity.cppm
export {
namespace telar::runtime::plugins {

using PackageDigest = std::array<std::uint8_t, 32>;

constexpr std::uint64_t stableId(std::string_view name) noexcept {
  std::uint64_t hash = 0xcbf29ce484222325;
  for (const unsigned char byte : name) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}

inline bool validEntrypoint(std::string_view path) noexcept {
  if (path.empty() || path.front() == '/') {
    return false;
  }
  for (;;) {
    const auto separator = path.find_first_of("/\\");
    const auto part = path.substr(0, separator);
    if (part.empty() || part == "." || part == "..") {
      return false;
    }
    if (separator == std::string_view::npos) {
      return true;
    }
    path.remove_prefix(separator + 1);
  }
}

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
  std::array<FixedText<PackageLimits::action_bytes>, PackageLimits::actions> actions;
  std::size_t action_count = 0;
  Capabilities capabilities;

  // Zig's `parseManifest`: the typed JSON read first, then each field's
  // check in Zig's order, failing with Zig's error names.
  template <Allocator Memory>
  inline static Manifest parse(Memory &memory, std::string_view bytes) {
    if (bytes.size() > PackageLimits::manifest_bytes) {
      throw std::invalid_argument{"ManifestTooLarge"};
    }

    std::optional<JsonValue> root;
    try {
      validateUtf8(bytes);
      root = JsonValue::parse(bytes);
    } catch (const std::exception &) {
      throw std::invalid_argument{syntaxFailure(bytes)};
    }

    Wire<Memory> wire{memory};
    try {
      wire.read(memory, *root);
    } catch (const JsonError &) {
      throw std::invalid_argument{"UnexpectedToken"};
    } catch (const std::invalid_argument &error) {
      throw std::invalid_argument{fieldFailure(error.what())};
    }

    return wire.validate();
  }

private:
  template <Allocator Memory>
  struct Wire {
    inline explicit Wire(Memory &memory)
        : id(AllocatorRef<char, Memory>{memory}),
          version(AllocatorRef<char, Memory>{memory}),
          entry(AllocatorRef<char, Memory>{memory}),
          url(AllocatorRef<char, Memory>{memory}),
          revision(AllocatorRef<char, Memory>{memory}),
          actions(AllocatorRef<String<Memory>, Memory>{memory}),
          capabilities(AllocatorRef<String<Memory>, Memory>{memory}) {}

    inline void read(Memory &memory, const JsonValue &root) {
      JsonFields fields{memory, root, field_names};
      api_version = number(fields.required("api_version"));
      fields.required("id").string(id);
      fields.required("version").string(version);
      fields.required("entry").string(entry);
      JsonFields origin{memory, fields.required("source"), source_names};
      origin.required("url").string(url);
      origin.required("revision").string(revision);
      for (auto [name, list] : {std::pair{"actions", &actions}, std::pair{"capabilities", &capabilities}}) {
        if (const auto &value = fields.optional(name)) {
          value->eachElement([&](const JsonValue &element) {
            element.string(list->emplace_back(AllocatorRef<char, Memory>{memory}));
          });
        }
      }
    }

    inline Manifest validate() const {
      constexpr std::uint64_t manifest_api = 1;
      if (api_version != manifest_api) {
        throw std::invalid_argument{"IncompatibleManifestApi"};
      }

      if (!validIdentifier(id) || id.size() > PackageLimits::id_bytes) {
        throw std::invalid_argument{"InvalidPluginId"};
      }

      if (version.empty() || version.size() > PackageLimits::version_bytes) {
        throw std::invalid_argument{"InvalidVersion"};
      }

      if (!validEntrypoint(entry) || entry.size() > PackageLimits::entry_bytes) {
        throw std::invalid_argument{"InvalidEntrypoint"};
      }

      if (url.empty() || url.size() > PackageLimits::source_bytes) {
        throw std::invalid_argument{"InvalidSource"};
      }

      if (revision.empty() || revision.size() > PackageLimits::revision_bytes) {
        throw std::invalid_argument{"InvalidRevision"};
      }

      if (actions.size() > PackageLimits::actions) {
        throw std::invalid_argument{"TooManyActions"};
      }

      Manifest manifest;
      manifest.id.assign(id);
      manifest.version.assign(version);
      manifest.entry.assign(entry);
      manifest.source.assign(url);
      manifest.revision.assign(revision);
      for (const auto &name : actions) {
        if (!validIdentifier(name) || name.size() > PackageLimits::action_bytes) {
          throw std::invalid_argument{"InvalidActionName"};
        }

        for (const auto &previous : std::span{manifest.actions}.first(manifest.action_count)) {
          if (previous.view() == name) {
            throw std::invalid_argument{"DuplicateAction"};
          }
        }

        manifest.actions[manifest.action_count++].assign(name);
      }

      for (const auto &name : capabilities) {
        manifest.capabilities.insert(Capabilities::parseName(name));
      }

      return manifest;
    }

    // A JSON number as Zig's typed read of a u16 takes it.
    inline static std::uint64_t number(const JsonValue &value) {
      const auto text = value.encoded();
      if (text.empty() || (text.front() != '-' && (text.front() < '0' || text.front() > '9'))) {
        throw std::invalid_argument{"UnexpectedToken"};
      }

      std::uint16_t result = 0;
      const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
      if (parsed.ec == std::errc::result_out_of_range) {
        throw std::invalid_argument{"Overflow"};
      }

      if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
        throw std::invalid_argument{"InvalidNumber"};
      }

      return result;
    }

    std::uint64_t api_version = 0;
    String<Memory> id;
    String<Memory> version;
    String<Memory> entry;
    String<Memory> url;
    String<Memory> revision;
    Vector<String<Memory>, Memory> actions;
    Vector<String<Memory>, Memory> capabilities;
  };

  // std.json's scanner: input that stops inside a string or an open object or
  // array ran out; anything else malformed is a syntax error.
  inline static const char *syntaxFailure(std::string_view text) noexcept {
    std::size_t depth = 0;
    bool in_string = false;
    bool escaped = false;
    for (const char byte : text) {
      if (in_string) {
        escaped = !escaped && byte == '\\';
        in_string = escaped || byte != '"';
      } else if (byte == '"') {
        in_string = true;
      } else if (byte == '{' || byte == '[') {
        ++depth;
      } else if ((byte == '}' || byte == ']') && depth != 0) {
        --depth;
      }
    }

    return in_string || depth != 0 || text.find_first_not_of(" \t\r\n") == std::string_view::npos ? "UnexpectedEndOfInput" : "SyntaxError";
  }

  // std.json's typed-read errors for JsonFields' refusals.
  inline static const char *fieldFailure(std::string_view message) noexcept {
    if (message == "Missing JSON field") {
      return "MissingField";
    }

    if (message == "Unknown JSON field") {
      return "UnknownField";
    }

    if (message == "Duplicate JSON field") {
      return "DuplicateField";
    }

    return message.data();
  }

  static constexpr auto field_names = std::to_array<std::string_view>({"api_version", "id", "version", "entry", "source", "actions", "capabilities"});
  static constexpr auto source_names = std::to_array<std::string_view>({"url", "revision"});
};

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

template <Allocator Memory>
void appendInspection(String<Memory> &output, const Package &package) {
  const auto &manifest = package.manifest;
  output += "id: ";
  output += manifest.id.view();
  output += "\nversion: ";
  output += manifest.version.view();
  output += "\nsource: ";
  output += manifest.source.view();
  output += "\nrevision: ";
  output += manifest.revision.view();
  output += "\ndigest: ";
  appendLowerHex(output, package.digest);
  output += "\nactions:";
  for (const auto &action : std::span{manifest.actions}.first(manifest.action_count)) {
    output += ' ';
    output += action.view();
  }
  output += "\ncapabilities:";
  for (unsigned index = 0; index < static_cast<unsigned>(Capability::count); ++index) {
    const auto capability = static_cast<Capability>(index);
    if (manifest.capabilities.contains(capability)) {
      output += ' ';
      output += Capabilities::name(capability);
    }
  }
  output += '\n';
}

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
    String<Memory> path;
    bool directory;
  };

  inline explicit PackageFiles(Memory &memory, int directory)
      : memory_(memory), entries_(AllocatorRef<Entry, Memory>{memory}) {
    String<Memory> prefix{AllocatorRef<char, Memory>{memory}};
    DirectoryStream iterator{directory};
    scan(iterator, prefix);
    std::ranges::sort(entries_, [](const auto &first, const auto &second) { return first.path < second.path; });
  }

  inline std::span<const Entry> entries() const noexcept { return entries_; }

private:
  inline void scan(DirectoryStream &iterator, String<Memory> &prefix) {
    const auto directory = iterator.descriptor();
    if (directory < 0) {
      throw SystemError{"Read plugin package directory descriptor"};
    }

    while (const auto *entry = iterator.next()) {
      if (entries_.size() == PackageLimits::files) {
        throw std::invalid_argument{"Too many plugin package entries"};
      }

      struct stat status{};
      if (::fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        throw SystemError{"Inspect plugin package entry"};
      }
      if (!S_ISREG(status.st_mode) && !S_ISDIR(status.st_mode)) {
        throw std::invalid_argument{"Unsupported plugin package file"};
      }

      const auto parent_length = prefix.size();
#if defined(__APPLE__)
      prefix.append(entry->d_name, entry->d_namlen);
#else
      prefix.append(entry->d_name);
#endif
      if (prefix.size() >= PATH_MAX) {
        throw std::invalid_argument{"Plugin package path exceeds its limit"};
      }
      entries_.push_back({String<Memory>{prefix, AllocatorRef<char, Memory>{memory_}}, S_ISDIR(status.st_mode)});
      if (S_ISDIR(status.st_mode)) {
        FileDescriptor child{::openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
        if (!child) {
          throw SystemError{"Open plugin package directory"};
        }
        prefix += '/';
        DirectoryStream children{std::move(child)};
        scan(children, prefix);
      }
      prefix.resize(parent_length);
    }
  }

  Memory &memory_;
  Vector<Entry, Memory> entries_;
};

template <Allocator Memory>
PackageFiles(Memory &memory, int directory) -> PackageFiles<Memory>;

}
}

// Interface: telar_plugins/package_copy_storage.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory, typename Inspector>
class PackageCopyStorage {
public:
  inline explicit PackageCopyStorage(Memory &memory) noexcept
      : memory_(&memory) {}

  inline auto copy(const Package &package, int destination, std::string_view path) -> Package {
    String<Memory> source_path{package.root.view(), AllocatorRef<char, Memory>{*memory_}};
    FileDescriptor source{telarOpenDirectoryNoFollow(source_path.c_str())};
    if (!source) {
      throw SystemError{"Open plugin package source"};
    }
    copyFiles(source, destination);

    auto copied = Inspector::inspect(*memory_, path);
    if (copied.manifest.id.view() != package.manifest.id.view() || copied.digest != package.digest) {
      throw std::invalid_argument{"Plugin changed while copying its package"};
    }
    return copied;
  }

private:
  inline void copyFiles(const FileDescriptor &source, int destination) {
    const PackageFiles files{*memory_, source.get()};
    std::size_t total = 0;
    for (const auto &entry : files.entries()) {
      if (entry.directory) {
        if (::mkdirat(destination, entry.path.c_str(), S_IRWXU) != 0) {
          throw SystemError{"Create plugin package directory"};
        }
        continue;
      }

      auto original = openBeneath(source.get(), entry.path, O_RDONLY);
      const auto contents = readFileContents(*memory_, original.get(), PackageLimits::total_bytes - total - 1);
      total += contents.size();
      auto copied = openBeneath(destination, entry.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
      const auto error = writeFile(copied, contents);
      if (error != 0) {
        throw SystemError{"Write plugin package file", error};
      }
    }
  }

  inline static auto writeFile(const FileDescriptor &destination, std::string_view bytes) noexcept -> int {
    while (!bytes.empty()) {
      const auto count = ::write(destination.get(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        return count == 0 ? EIO : errno;
      }

      bytes.remove_prefix(static_cast<std::size_t>(count));
    }

    return 0;
  }

  Memory *memory_;
};

}
}

// Interface: telar_plugins/package_inspection.cppm
export {
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
  inline static Package inspectConfigured(Memory &memory, std::string_view directory, std::string_view path) {
    String<Memory> resolved{path, AllocatorRef<char, Memory>{memory}};
    resolveRelativePath(resolved, directory);
    return inspect(memory, resolved);
  }

  template <Allocator Memory>
  inline static Package inspect(Memory &memory, std::string_view path) {
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
  inline static PackageDigest digest(Memory &memory, int directory) {
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

  inline static void hashLength(Hash &hash, std::uint64_t length) {
    std::array<char, sizeof(length)> encoded;
    for (std::size_t index = 0; index < encoded.size(); ++index) {
      encoded[index] = static_cast<char>(length & UINT8_MAX);
      length >>= std::numeric_limits<std::uint8_t>::digits;
    }
    hash.update({encoded.data(), encoded.size()});
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
PackageCopy(Memory &memory) -> PackageCopy<Memory>;

}
}

// Interface: telar_plugins/package_installation.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageInstallation {
public:
  inline explicit PackageInstallation(Memory &memory) noexcept : memory_(memory) {}

  inline void install(const Package &package, std::string_view destination) {
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
  inline bool existing(const Package &package, const char *path) {
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
}

// Interface: telar_plugins/specifications.cppm
export {
namespace telar::runtime::plugins {

struct ConfiguredPlugin {
  FixedText<PackageLimits::configured_path_bytes> path;
  bool enabled = true;
};

struct Specifications {
  std::array<ConfiguredPlugin, PackageLimits::configured> entries;
  std::size_t count = 0;

  inline std::span<const ConfiguredPlugin> configured() const noexcept {
    return std::span{entries}.first(count);
  }
};

}
}

// Interface: telar_plugins/package_registry_storage.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory, typename Inspector>
class PackageRegistryStorage {
public:
  inline explicit PackageRegistryStorage(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications)
      : packages_(AllocatorRef<Package, Memory>{memory}) {
    for (const auto &specification : specifications) {
      if (!specification.enabled) {
        continue;
      }
      if (packages_.size() == PackageLimits::configured) {
        throw std::invalid_argument{"Too many configured plugins"};
      }

      auto package = Inspector::inspectConfigured(memory, directory, specification.path.view());
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

  inline std::span<const Package> packages() const noexcept {
    return packages_;
  }

private:
  Vector<Package, Memory> packages_;
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
PackageRegistry(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications) -> PackageRegistry<Memory>;

}
}

// Interface: telar_plugins/paths.cppm
export {
namespace telar::runtime::plugins {

class Paths {
public:
  template <Allocator Memory, EnvironmentLookup Environment>
  inline static String<Memory> trust(Memory &memory, const Environment &environment) {
    auto path = base(memory, environment, "XDG_CONFIG_HOME", "/.config");
    path += "/telar/trust.json";
    return path;
  }

  template <Allocator Memory, EnvironmentLookup Environment>
  inline static String<Memory> installation(Memory &memory, const Environment &environment, const Package &package) {
    auto path = base(memory, environment, "XDG_DATA_HOME", "/.local/share");
    path += "/telar/plugins/";
    path += package.manifest.id.view();
    path += '/';
    appendLowerHex(path, package.digest);
    return path;
  }

private:
  template <Allocator Memory, EnvironmentLookup Environment>
  inline static String<Memory> base(Memory &memory, const Environment &environment, const char *variable, std::string_view fallback) {
    String<Memory> path{environment.lookup(variable), AllocatorRef<char, Memory>{memory}};
    if (path.empty()) {
      path = environment.lookup("HOME");
      if (path.empty()) {
        throw std::invalid_argument{"Home directory unavailable for plugins"};
      }
      path += fallback;
    }
    return path;
  }
};

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
  inline std::span<const TrustGrant> grants() const noexcept {
    return std::span{grants_}.first(count_);
  }

  template <Allocator Memory>
  inline static TrustStore load(Memory &memory, std::string_view path) {
    Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory}};
    if (!readPrivateFile(AT_FDCWD, path, bytes, PackageLimits::trust_bytes - 1)) {
      return {};
    }
    return parse(memory, {reinterpret_cast<const char *>(bytes.data()), bytes.size()});
  }

  template <Allocator Memory>
  inline static TrustStore parse(Memory &memory, std::string_view bytes) {
    validateUtf8(bytes);
    JsonFields root{memory, JsonValue::parse(bytes), root_fields};
    if (!SchemaVersion<Memory>::isOne(memory, root.required("version"))) {
      throw std::invalid_argument{"Incompatible plugin trust store"};
    }

    TrustStore store;
    root.required("grants").eachElement([&](const JsonValue &value) {
      if (store.count_ == PackageLimits::grants) {
        throw std::invalid_argument{"Too many plugin trust grants"};
      }
      JsonFields fields{memory, value, grant_fields};
      auto &grant = store.grants_[store.count_];
      grant.plugin.assign(fields.string("plugin"));
      if (!validIdentifier(grant.plugin.view())) {
        throw std::invalid_argument{"Invalid trusted plugin ID"};
      }
      for (const auto &existing : std::span{store.grants_}.first(store.count_)) {
        if (existing.plugin.view() == grant.plugin.view()) {
          throw std::invalid_argument{"Duplicate plugin trust grant"};
        }
      }
      grant.digest = parseDigest(fields.string("digest"));
      grant.capabilities = Capabilities::parse(memory, fields.required("capabilities"));
      ++store.count_;
    });
    return store;
  }

  inline Capabilities granted(std::string_view id, const PackageDigest &digest) const noexcept {
    for (const auto &grant : std::span{grants_}.first(count_)) {
      if (stableId(grant.plugin.view()) == stableId(id) && grant.digest == digest) {
        return grant.capabilities;
      }
    }
    return {};
  }

  inline void upsert(const Manifest &manifest, const PackageDigest &digest, Capabilities capabilities) {
    for (auto &entry : std::span{grants_}.first(count_)) {
      if (entry.plugin.view() == manifest.id.view()) {
        entry.digest = digest;
        entry.capabilities = capabilities;
        return;
      }
    }
    if (count_ == grants_.size()) {
      throw std::invalid_argument{"Too many plugin trust grants"};
    }

    auto &entry = grants_[count_++];
    entry.plugin = manifest.id;
    entry.digest = digest;
    entry.capabilities = capabilities;
  }

  inline bool revoke(std::string_view id) {
    if (!validIdentifier(id)) { throw std::invalid_argument{"Invalid plugin ID"}; }
    for (std::size_t index = 0; index < count_; ++index) {
      if (grants_[index].plugin.view() != id) { continue; }
      for (std::size_t next = index + 1; next < count_; ++next) { grants_[next - 1] = grants_[next]; }
      --count_;
      return true;
    }
    return false;
  }

  template <Allocator Memory>
  inline String<Memory> json(Memory &memory) const {
    String<Memory> output{"{\"version\":1,\"grants\":[", AllocatorRef<char, Memory>{memory}};
    for (std::size_t index = 0; index < count_; ++index) {
      if (index != 0) {
        output += ',';
      }
      const auto &entry = grants_[index];
      output += "{\"plugin\":";
      appendJsonString(output, entry.plugin.view());
      output += ",\"digest\":\"";
      appendLowerHex(output, entry.digest);
      output += "\",\"capabilities\":[";
      bool first = true;
      for (unsigned value = 0; value < static_cast<unsigned>(Capability::count); ++value) {
        const auto capability = static_cast<Capability>(value);
        if (entry.capabilities.contains(capability)) {
          if (!first) {
            output += ',';
          }
          appendJsonString(output, Capabilities::name(capability));
          first = false;
        }
      }
      output += "]}";
    }
    output += "]}\n";
    if (output.size() > PackageLimits::trust_bytes) {
      throw std::length_error{"Plugin trust store exceeds its limit"};
    }
    return output;
  }

  inline static PackageDigest parseDigest(std::string_view text) {
    PackageDigest digest;
    if (text.size() != digest.size() * 2) {
      throw std::invalid_argument{"Invalid plugin digest"};
    }
    for (std::size_t index = 0; index < digest.size(); ++index) {
      digest[index] = static_cast<std::uint8_t>((hex(text[2 * index]) << 4) | hex(text[2 * index + 1]));
    }
    return digest;
  }

private:
  inline static unsigned hex(char byte) {
    if (byte >= '0' && byte <= '9') {
      return static_cast<unsigned>(byte - '0');
    }
    if (byte >= 'a' && byte <= 'f') {
      return static_cast<unsigned>(byte - 'a' + 10);
    }
    if (byte >= 'A' && byte <= 'F') {
      return static_cast<unsigned>(byte - 'A' + 10);
    }
    throw std::invalid_argument{"Invalid plugin digest"};
  }

  static constexpr auto root_fields = std::to_array<std::string_view>({"version", "grants"});
  static constexpr auto grant_fields = std::to_array<std::string_view>({"plugin", "digest", "capabilities"});
  std::array<TrustGrant, PackageLimits::grants> grants_;
  std::size_t count_ = 0;
};

}
}

// Interface: telar_plugins/trust_update.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
void saveTrust(Memory &memory, const TrustStore &store, String<Memory> path) {
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

template <Allocator Memory>
void updateTrust(Memory &memory, const Package &package, Capabilities capabilities, String<Memory> path) {
  auto store = TrustStore::load(memory, path);
  store.upsert(package.manifest, package.digest, capabilities);
  saveTrust(memory, store, std::move(path));
}

template <Allocator Memory>
void revokeTrust(Memory &memory, std::string_view id, String<Memory> path) {
  auto store = TrustStore::load(memory, path);
  store.revoke(id);
  saveTrust(memory, store, std::move(path));
}

}
}
