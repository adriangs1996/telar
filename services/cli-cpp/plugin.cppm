module;
#include <new>
#include <stdlib.h>

#include <cstdint>
#include <cerrno>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif
#include <sys/stat.h>
#include <unistd.h>


#include <cstddef>
#include <fcntl.h>
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <dirent.h>
#include "telar_platform/open_directory.h"
#include <openssl/sha.h>

#include <spawn.h>
#include <sys/wait.h>
#include <cstring>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <arpa/inet.h>
#include <ctime>
#include <openssl/crypto.h>

export module telar.cli.plugin;

import std;

export import telar.cli.command_limit;
export import telar.cli.server;
export import telar.platform;


export import telar.plugins;


export import telar.tls;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: cli_install.cppm
export {
namespace telar::runtime::cli {

inline CommandError fileError(int code) {
  return CommandError{code == ENOENT ? "FileNotFound" : code == EACCES || code == EPERM ? "AccessDenied"
                                                    : code == ENOTDIR                   ? "NotDir"
                                                    : code == EINVAL                    ? "NotLink"
                                                    : code == ENAMETOOLONG              ? "NameTooLong"
                                                                                        : "Unexpected"};
}

struct CliInstallOptions {
  std::string_view action;
  std::optional<std::string_view> directory;
};

inline CliInstallOptions parseCliInstall(std::span<char *const> args) {
  if (args.empty()) {
    throw std::invalid_argument{"MissingCliAction"};
  }

  const std::string_view action = args[0];
  if (action != "install" && action != "uninstall" && action != "status") {
    throw std::invalid_argument{"UnknownCliAction"};
  }

  std::optional<std::string_view> directory;
  Cursor cursor{args.subspan(1)};
  while (const auto word = cursor.next()) {
    if (*word != "--dir") {
      throw std::invalid_argument{"UnknownCliOption"};
    }

    if (directory) {
      throw std::invalid_argument{"DuplicateDirOption"};
    }

    directory = cursor.take("MissingDirPath");
  }

  return {.action = action, .directory = directory};
}

inline int runCliInstall(std::span<char *const> args) {
  const auto options = parseCliInstall(args);
  const auto action = options.action;
  const auto directory = options.directory;

  const auto path = std::string{directory.value_or("/usr/local/bin")} + "/telar";
  const ExecutablePath target;
  std::array<char, PATH_MAX> buffer;
  const auto count = ::readlink(path.c_str(), buffer.data(), buffer.size());
  if (count < 0 && errno != ENOENT) {
    if (errno == EINVAL && action != "status") {
      std::fprintf(stderr, "telar cli: %s exists and is not a symlink; refusing to replace it\n", path.c_str());
    }

    throw fileError(errno);
  }

  if (action == "status") {
    if (count < 0) {
      std::printf("telar cli: %s is not installed\n", path.c_str());
    } else {
      std::printf("telar cli: %s -> %.*s\n", path.c_str(), static_cast<int>(count), buffer.data());
    }

    return 0;
  }

  if (count >= 0 && ::unlink(path.c_str()) != 0) {
    throw fileError(errno);
  }

  if (action == "install") {
    if (::symlink(target.c_str(), path.c_str()) != 0) {
      const auto failure = errno;
      if (failure == EACCES || failure == EPERM) {
        std::fprintf(stderr, "telar cli: cannot write %s; rerun with sudo or pass --dir ~/.local/bin\n", path.c_str());
      }

      throw fileError(failure);
    }

    std::printf("telar cli: installed %s -> %s\n", path.c_str(), target.c_str());
  } else {
    std::printf("telar cli: removed %s\n", path.c_str());
  }

  return 0;
}

}
}

// Interface: plugin_options.cppm
export {
namespace telar::runtime::cli {

enum class PluginAction { inspect,
                          install,
                          trust,
                          untrust };

struct PluginOptions {
  PluginAction action;
  std::string_view path;
  std::array<plugins::Capability, static_cast<std::size_t>(plugins::Capability::count)> capabilities{};
  std::size_t capability_count = 0;

  // Zig's `PluginOptions.parse`, with its error names; `untrust` is the C++
  // runtime's addition.
  inline static PluginOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2) {
      usage("MissingPluginArguments");
    }

    PluginOptions options{.action = parseAction(arguments[0]), .path = arguments[1]};
    for (std::size_t index = 2; index < arguments.size(); index += 2) {
      if (std::string_view{arguments[index]} != "--capability" || index + 1 >= arguments.size()) {
        usage("InvalidPluginArguments");
      }

      if (options.capability_count == options.capabilities.size()) {
        usage("TooManyPluginCapabilities");
      }

      options.capabilities[options.capability_count++] = plugins::Capabilities::parseName(arguments[index + 1]);
    }

    if (options.action != PluginAction::trust && options.capability_count != 0) {
      usage("InvalidPluginArguments");
    }

    return options;
  }

private:
  inline static PluginAction parseAction(std::string_view action) {
    if (action == "inspect") {
      return PluginAction::inspect;
    }
    if (action == "install") {
      return PluginAction::install;
    }
    if (action == "trust") {
      return PluginAction::trust;
    }
    if (action == "untrust") {
      return PluginAction::untrust;
    }
    usage("UnknownPluginAction");
  }
};

}
}

// Interface: plugin.cppm
export {
namespace telar::runtime::cli {

// Zig's `grantedCapabilities`: the manifest's, or the requested ones, each
// declared there and named once.
inline plugins::Capabilities grantedCapabilities(const plugins::Manifest &manifest, const PluginOptions &options) {
  if (options.capability_count == 0) {
    return manifest.capabilities;
  }

  plugins::Capabilities granted;
  for (const auto capability : std::span{options.capabilities}.first(options.capability_count)) {
    if (!manifest.capabilities.contains(capability)) {
      throw std::runtime_error{"CapabilityNotDeclared"};
    }

    granted.insert(capability);
  }

  return granted;
}

template <Allocator Memory, EnvironmentLookup Environment>
void executePlugin(Memory &memory, const PluginOptions &options, const Environment &environment) {
  if (options.action == PluginAction::untrust) {
    plugins::revokeTrust(memory, options.path, plugins::Paths::trust(memory, environment));
    constexpr std::string_view message = "telar plugin trust revoked\n";
    const auto written = writeDescriptor(STDOUT_FILENO, {reinterpret_cast<const std::uint8_t *>(message.data()), message.size()});
    if (written != 0) { throw SystemError{"Write plugin command output", written}; }
    return;
  }
  const auto package = plugins::PackageInspector::inspect(memory, options.path);
  String<Memory> output{AllocatorRef<char, Memory>{memory}};
  switch (options.action) {
  case PluginAction::inspect:
    plugins::appendInspection(output, package);
    break;
  case PluginAction::install: {
    const auto destination = plugins::Paths::installation(memory, environment, package);
    plugins::PackageInstallation{memory}.install(package, destination);
    output = "telar plugin installed: ";
    output += destination;
    output += '\n';
    break;
  }
  case PluginAction::trust:
    plugins::updateTrust(memory, package, grantedCapabilities(package.manifest, options), plugins::Paths::trust(memory, environment));
    output = "telar plugin trust updated\n";
    break;
  case PluginAction::untrust:
    break;
  }

  const auto written = writeDescriptor(STDOUT_FILENO, {reinterpret_cast<const std::uint8_t *>(output.data()), output.size()});
  if (written != 0) {
    throw SystemError{"Write plugin command output", written};
  }
}

// As Zig's `plugin.run`, a failure after the arguments parsed prints
// `error: NAME` with Zig's error name.
template <Allocator Memory, EnvironmentLookup Environment>
void runPlugin(Memory &memory, const PluginOptions &options, const Environment &environment) {
  try {
    executePlugin(memory, options, environment);
  } catch (const SystemError &error) {
    throw CommandError{systemErrorName(error.code())};
  } catch (const std::exception &error) {
    throw CommandError{error.what()};
  }
}

}
}

// Interface: proxy_options.cppm
export {
namespace telar::runtime::cli {

enum class ProxyTrustAction { install,
                              uninstall,
                              status };

struct ProxyTrustOptions {
  ProxyTrustAction action = ProxyTrustAction::status;
  std::string_view directory;
  std::string_view linux_backend;

  // Zig's `ProxyOptions.parse`, with its error names.
  inline static ProxyTrustOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2 || std::string_view{arguments[0]} != "trust") {
      usage("MissingProxyTrustAction");
    }

    ProxyTrustOptions options;
    const std::string_view action = arguments[1];
    if (action == "install") {
      options.action = ProxyTrustAction::install;
    } else if (action == "uninstall") {
      options.action = ProxyTrustAction::uninstall;
    } else if (action != "status") {
      usage("UnknownProxyTrustAction");
    }

    for (std::size_t index = 2; index < arguments.size(); index += 2) {
      const std::string_view option = arguments[index];
      if (option == "--ca-dir") {
        if (!options.directory.empty() || index + 1 >= arguments.size() || std::string_view{arguments[index + 1]}.empty()) {
          usage("InvalidProxyTrustDirectory");
        }

        options.directory = arguments[index + 1];
      } else if (option == "--linux") {
        const std::string_view backend = index + 1 < arguments.size() ? std::string_view{arguments[index + 1]} : std::string_view{};
        if (!options.linux_backend.empty() || (backend != "update-ca-certificates" && backend != "trust")) {
          usage("InvalidLinuxTrustBackend");
        }

        options.linux_backend = backend;
      } else {
        usage("UnknownProxyTrustOption");
      }
    }

    return options;
  }
};

}
}

// Interface: proxy_trust.cppm
export {
namespace telar::runtime::cli {

template <ConcurrentAllocator Memory, EnvironmentLookup Environment>
int runProxyTrust(Memory &memory, const ProxyTrustOptions &options, const Environment &environment) {
  const auto directory = options.directory.empty() ? proxyAuthorityDirectory(memory, environment) : String<Memory>{options.directory, AllocatorRef<char, Memory>{memory}};
  if (directory.empty() || directory.front() != '/') {
    std::fputs("telar proxy trust: --ca-dir must be absolute\n", stderr);
    return 1;
  }

  const proxy_trust::Paths paths{memory, directory};
  std::optional<proxy_trust::Backend> selected;
  if (!options.linux_backend.empty()) {
    selected = options.linux_backend == "trust" ? proxy_trust::Backend::trust : proxy_trust::Backend::update_ca_certificates;
  }
  // As Zig's `selectBackend`, only installation chooses a backend; status
  // and removal ignore --linux.
  if (options.action == ProxyTrustAction::install) {
#if defined(__APPLE__)
    if (selected) {
      throw CommandError{"LinuxTrustFlagOnMacOS"};
    }
#elif defined(__linux__)
    if (!selected) {
      throw CommandError{"LinuxTrustBackendRequired"};
    }
#endif
  }

#if defined(__APPLE__)
  selected.reset();
#endif
  const auto destination = paths.nativeDestination(memory, environment, selected);
  const TlsLibrary library{memory};
  proxy_trust::SystemCommand command{memory, stdout};
  proxy_trust::Service service{memory, library, paths, command, destination};
  const auto current = service.inspect();
  const auto certificate = paths.file(AuthorityFiles::forKind(AuthorityKind::system_trust).certificate);
  const auto print_notice = [&] {
    std::printf("Firefox may use its own certificate store; import %s there if it does not honor OS trust.\n", certificate.c_str());
  };

  if (options.action == ProxyTrustAction::status) {
    std::printf("telar proxy trust: %s (%s)\n", proxy_trust::statusName(current.status).data(), directory.c_str());
    if (current.record) {
      const auto &record = *current.record;
      std::printf("fingerprint: %.*s\nstore: %.*s\n", static_cast<int>(record.fingerprint.size()), record.fingerprint.data(), static_cast<int>(record.store.view().size()), record.store.view().data());
    }

    print_notice();
    return current.status == proxy_trust::Status::stale ? 1 : 0;
  }
  if (current.status == proxy_trust::Status::stale && !current.record) {
    const auto record = paths.file(proxy_trust::Record::filename);
    std::printf("telar proxy trust: invalid trust record (%s)\n", record.c_str());
    return 1;
  }

  if (options.action == ProxyTrustAction::install) {
    if (current.status == proxy_trust::Status::installed) {
      std::printf("telar proxy trust: already installed (%s)\n", directory.c_str());
    } else {
      const auto record = service.install(current.record);
      std::printf("telar proxy trust: installed %.*s\n", static_cast<int>(record.fingerprint.size()), record.fingerprint.data());
    }

    print_notice();
    return 0;
  }

  if (!current.record) {
    std::printf("telar proxy trust: not installed (%s)\n", directory.c_str());
    return 0;
  }

  service.uninstall(*current.record);
  std::printf("telar proxy trust: removed %.*s\n", static_cast<int>(current.record->fingerprint.size()), current.record->fingerprint.data());
  return 0;
}

}
}

// Interface: routed_options.cppm
export {
namespace telar::runtime::cli {

// Each `ClientAction` as Zig's `@tagName` prints it, in the enum's order.
inline constexpr std::array<std::string_view, 34> client_action_names{
    "workspace_select", "tab_create", "tab_select", "tab_next", "tab_previous", "pane_create", "pane_split",
    "pane_close", "pane_focus", "pane_resize", "pane_fullscreen", "pane_scroll", "sidebar_get", "sidebar_show",
    "sidebar_hide", "sidebar_resize", "workspace_list_expand", "workspace_list_collapse", "client_open_goto",
    "client_open_history", "client_copy_mode", "notification_dismiss", "client_open_link", "client_clipboard_copy",
    "pane_copy", "layout_get", "layout_apply", "config_reload", "config_show", "plugin_list", "plugin_get",
    "plugin_enable", "plugin_disable", "plugin_run"};

inline constexpr std::array<std::string_view, 4> pane_directions{"left", "right", "up", "down"};

inline std::string_view clientActionName(ClientAction action) {
  return client_action_names.at(static_cast<std::size_t>(action));
}

// `CopySelection.fromText`: "ROW,COLUMN:ROW,COLUMN".
inline void copyRange(std::string_view text) {
  const auto colon = text.find(':');
  if (colon == std::string_view::npos) {
    usage("InvalidCopyRange");
  }

  for (const auto point : {text.substr(0, colon), text.substr(colon + 1)}) {
    const auto comma = point.find(',');
    if (comma == std::string_view::npos) {
      usage("InvalidCopyRange");
    }

    number<std::uint16_t>(point.substr(0, comma), "InvalidCopyRange");
    number<std::uint32_t>(point.substr(comma + 1), "InvalidCopyRange");
  }
}

// A command a window performs, as Zig's `arguments/RoutedOptions.zig`: the
// family and verb name a `ClientAction` ("pane copy" is `pane_copy`), and the
// runtime forwards it to the client `--client` names.
struct RoutedOptions {
  ClientAction action{};
  std::uint64_t client_id = 0;
  std::uint64_t target_id = 0;
  std::int64_t value = 0;
  std::string_view text{};
  bool json = false;
  const char *socket = nullptr;

  // `words` starts at the family. Not a routed command: nullopt, so the
  // family's own parser reads it.
  inline static std::optional<RoutedOptions> parse(Arguments words) {
    if (words.size() < 2) {
      return std::nullopt;
    }

    const std::string_view group = words[0];
    const std::string_view verb = words[1];
    const bool nested = group == "client" && (verb == "open" || verb == "clipboard");
    const std::size_t consumed = nested ? 3 : 2;
    if (words.size() < consumed) {
      usage("MissingClientAction");
    }

    const auto action = parseAction(group, verb, nested ? std::string_view{words[2]} : std::string_view{});
    if (!action || excluded(*action, words.subspan(2))) {
      return std::nullopt;
    }

    RoutedOptions self{.action = *action};
    Cursor cursor{words.subspan(consumed)};
    self.positionals(cursor);
    self.options(cursor);
    if (self.client_id == 0) {
      usage("MissingClientId");
    }

    return self;
  }

private:
  inline static std::optional<ClientAction> parseAction(std::string_view group, std::string_view verb, std::string_view nested) {
    constexpr std::size_t name_limit = 64;
    std::string name{group};
    name += '_';
    name += verb;
    if (!nested.empty()) {
      name += '_';
      name += nested;
    }

    if (name.size() > name_limit) {
      return std::nullopt;
    }

    std::ranges::replace(name, '-', '_');
    const auto found = std::ranges::find(client_action_names, name);
    if (found == client_action_names.end()) {
      return std::nullopt;
    }

    return static_cast<ClientAction>(found - client_action_names.begin());
  }

  // A tab created in the background never reaches a UI: the runtime opens it.
  // Focusing the current pane or a neighbor is the runtime's, too.
  inline static bool excluded(ClientAction action, Arguments rest) {
    const auto contains = [&](std::string_view word) { return std::ranges::any_of(rest, [&](const char *argument) { return word == argument; }); };
    if (action == ClientAction::tab_create) {
      return contains("--background");
    }

    if (action == ClientAction::pane_focus) {
      return contains("--current") || contains("--direction");
    }

    return false;
  }

  inline void positionals(Cursor &cursor) {
    using enum ClientAction;
    switch (action) {
    case plugin_run:
      text = cursor.take("MissingPlugin");
      target_id = plugins::stableId(cursor.take("MissingPluginAction"));
      break;
    case plugin_disable:
    case plugin_enable:
    case plugin_get:
      text = cursor.take("MissingPlugin");
      break;
    case layout_apply:
      text = cursor.take("MissingLayoutToken");
      break;
    case pane_copy:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      text = cursor.take("MissingCopyRange");
      copyRange(text);
      break;
    case client_clipboard_copy:
    case client_open_link:
      text = cursor.take("MissingText");
      break;
    case sidebar_resize: {
      const auto width = positive(cursor.take("MissingWidth"), "InvalidTarget");
      if (width > std::numeric_limits<std::uint16_t>::max()) {
        usage("InvalidWidth");
      }

      value = static_cast<std::int64_t>(width);
      break;
    }
    case pane_scroll:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      value = signedNumber<std::int32_t>(cursor.take("MissingScrollDelta"), "InvalidScrollDelta");
      break;
    case pane_resize:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      text = cursor.take("MissingPaneDirection");
      choice<PaneDirection>(text, "InvalidPaneDirection", pane_directions);
      break;
    case pane_split:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      text = cursor.take("MissingSplitAxis");
      if (text != "horizontal" && text != "vertical") {
        usage("InvalidSplitAxis");
      }
      break;
    case notification_dismiss:
    case pane_fullscreen:
    case pane_focus:
    case pane_close:
    case tab_select:
    case workspace_select:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      break;
    default:
      break;
    }
  }

  inline void options(Cursor &cursor) {
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--client" && client_id == 0) {
        client_id = positive(cursor.take("MissingClientId"), "InvalidTarget");
      } else if (arg == "--label" && action == ClientAction::tab_create && text.empty()) {
        text = cursor.take("MissingLabel");
      } else if (arg == "--section" && action == ClientAction::config_show && text.empty()) {
        text = cursor.take("MissingSection");
      } else if (arg == "--index" && action == ClientAction::config_show) {
        value = number<std::uint16_t>(cursor.take("MissingIndex"), "InvalidIndex");
      } else if (arg == "--json" && !json) {
        json = true;
      } else if (arg == "--socket" && socket == nullptr) {
        socket = cursor.take("MissingSocketPath").data();
      } else {
        usage("UnknownClientCommandOption");
      }
    }
  }
};

}
}
