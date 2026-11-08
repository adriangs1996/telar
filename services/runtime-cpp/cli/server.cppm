module;
#include <stdlib.h>
#include <ghostty/vt.h>
#include <sys/mman.h>

#include <cstdint>

#include "config_bootstrap.hpp"
#include <cinttypes>
#include <cstdio>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <cstring>
#include <cmath>
#include <cstddef>
#include <limits.h>
#include <sys/stat.h>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

#if (defined(__APPLE__))
#include <sys/socket.h>
#endif
#if (defined(__APPLE__))
#include <sys/types.h>
#endif
#if (defined(__APPLE__))
#include <csignal>
#endif
#if (defined(__APPLE__))
#include <poll.h>
#endif
#if (defined(__APPLE__))
#include <sys/un.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <net/if.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <net/if_utun.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <netinet6/in6_var.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <sys/kern_control.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <sys/socket.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <sys/sys_domain.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <arpa/inet.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <linux/if_ether.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <linux/if_tun.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <net/if.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <sys/uio.h>
#endif
#if (defined(__APPLE__))
#include <arpa/inet.h>
#endif
#if (defined(__APPLE__))
#include <pcap/pcap.h>
#endif
#if (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__))
#include <netinet/in.h>
#endif
#if (defined(__APPLE__))
#include <ifaddrs.h>
#endif
#if (defined(__APPLE__))
#include <net/if.h>
#endif
#if (defined(__APPLE__)) && (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__APPLE__)) && (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__APPLE__))
#include <cstdlib>
#endif
#if (defined(__APPLE__))
#include <sys/file.h>
#endif
#if (defined(__APPLE__))
#include <sys/sockio.h>
#endif
#if (defined(__APPLE__))
#include <netinet/tcp.h>
#endif
#if (defined(__APPLE__))
#include <net/if_dl.h>
#endif
#if (defined(__APPLE__))
#include <net/route.h>
#endif
#if (defined(__APPLE__))
#include <sys/uio.h>
#endif
#if (defined(__APPLE__))
#include <netinet/in_pcb.h>
#endif
#if (defined(__APPLE__))
#include <netinet/tcp_fsm.h>
#endif
#if (defined(__APPLE__))
#include <netinet/tcp_var.h>
#endif
#if (defined(__APPLE__))
#include <sys/socketvar.h>
#endif
#if (defined(__APPLE__))
#include <sys/sysctl.h>
#endif
#if (defined(__APPLE__)) && (defined(__APPLE__))
#include <libproc.h>
#endif
#if (defined(__APPLE__)) && (!(defined(__APPLE__)))
#include <dirent.h>
#endif

#include <ghostty/vt/unicode.h>
#include <arpa/inet.h>
#include <cstdlib>
#include <sqlite3.h>
#include <cassert>
#include <poll.h>
#include <sys/uio.h>
#include <sys/types.h>
#include <climits>
#include <csignal>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <dirent.h>
#include "telar_platform/open_directory.h"
#include <openssl/sha.h>
#include <pthread.h>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>
#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#endif
#if (defined(__APPLE__))
#include <Security/Security.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/err.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/pem.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#include <sys/un.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <netdb.h>
#include <brotli/encode.h>
#include <nghttp2/nghttp2.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/crypto.h>
#include <ctime>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include <spawn.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include "telar_base/diagnostics/config.hpp"
#if (TELAR_DIAGNOSTICS) && (defined(__APPLE__))
#include <mach/mach.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include <sys/mman.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include "cell_layout.hpp"
#endif
#include <sys/file.h>
#include <new>
#include <termios.h>
#include <ifaddrs.h>
#include <net/if.h>
#if (defined(__APPLE__))
#include <libproc.h>
#endif
#include <pcap/pcap.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif


export module telar.runtime.cli.server;

import std;

export import telar.config;


export import telar.runtime.plugins.tap_configuration;
export import telar.lua;
export import telar.platform;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;


#if (defined(__APPLE__))
export import telar.runtime.redirect.socket_owners;
#endif
#if (!(defined(__APPLE__)))
export import telar.platform;
#endif


export import telar.runtime.config.loader;
export import telar.runtime.history.event;
export import telar.runtime.plugins.service;
export import telar.runtime.proxy.runtime;
export import telar.runtime.runtime.media_service;
export import telar.runtime.runtime.delivery.client_delivery;
export import telar.runtime.runtime.runtime;
export import telar.runtime.runtime.background_executor;
export import telar.runtime.traffic.control_backend;
export import telar.runtime.traffic.tap;


export import telar.runtime.traffic.capture;

// Interface: cli/plugin_worker_options.cppm
export {
namespace telar::runtime::cli {

struct PluginWorkerOptions {
  const char *entry = nullptr;
  const char *action = nullptr;
  config::BindingContext context;

  inline static PluginWorkerOptions parse(std::span<char *> arguments) {
    constexpr std::size_t argument_count = 7;
    if (arguments.size() != argument_count) {
      throw std::invalid_argument{"Expected plugin-worker ENTRY ACTION SIDEBAR TAB_COUNT ACTIVE_TAB_INDEX PANE_COUNT FOCUSED_PANE_ID"};
    }

    const std::string_view sidebar{arguments[2]};
    if (sidebar != "0" && sidebar != "1") {
      throw std::invalid_argument{"Invalid plugin worker sidebar flag"};
    }

    const std::string_view action{arguments[1]};
    if (action.empty()) {
      throw std::invalid_argument{"Empty plugin action"};
    }

    for (const char byte : action) {
      if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-' || byte == '.')) {
        throw std::invalid_argument{"Invalid plugin action name"};
      }
    }

    const config::BindingContext context{
        .sidebar_visible = sidebar == "1",
        .tab_count = number<std::uint16_t>(arguments[3]),
        .active_tab_index = number<std::uint16_t>(arguments[4]),
        .pane_count = number<std::uint16_t>(arguments[5]),
        .focused_pane_id = number<std::uint64_t>(arguments[6]),
    };
    return {.entry = arguments[0], .action = arguments[1], .context = context};
  }

private:
  template <typename Integer>
  inline static Integer number(std::string_view text) {
    if (text.empty() || text.front() == '_' || text.back() == '_') {
      throw std::invalid_argument{"Invalid plugin worker integer"};
    }

    Integer result = 0;
    constexpr unsigned radix = 10;
    for (const char byte : text) {
      if (byte == '_') {
        continue;
      }

      if (byte < '0' || byte > '9') {
        throw std::invalid_argument{"Invalid plugin worker integer"};
      }

      const auto digit = static_cast<unsigned>(byte - '0');
      if (result > (std::numeric_limits<Integer>::max() - digit) / radix) {
        throw std::invalid_argument{"Plugin worker integer exceeds its bounds"};
      }

      result = static_cast<Integer>((result * radix) + digit);
    }

    return result;
  }
};

}
}

// Interface: cli/plugin_worker.cppm
export {
namespace telar::runtime::cli {

// Keep the reference worker lexical scope and its mutable Lua binding factory.
template <Allocator Memory>
String<Memory> pluginCallbackSource(Memory &memory, std::string_view source, std::string_view action) {
  constexpr std::string_view prefix = "local telar = require(\"telar\")\nlocal plugin = (function()\n";
  constexpr std::string_view middle = "\nend)()\nif type(plugin) ~= \"table\" or type(plugin.actions) ~= \"table\" then error(\"plugin must return a table with an actions table\") end\nlocal callback = plugin.actions[\"";
  constexpr std::string_view suffix = "\"]\nif type(callback) ~= \"function\" then error(\"plugin action is not a function\") end\nreturn {telar.bind_global({\"escape\"}, callback)}";
  String<Memory> wrapped{AllocatorRef<char, Memory>{memory}};
  wrapped.reserve(prefix.size() + source.size() + middle.size() + action.size() + suffix.size());
  wrapped.append(prefix).append(source).append(middle).append(action).append(suffix);

  return wrapped;
}

inline int retainPluginCallback(lua_State *state, const config::RetainedActionValidator &validator, config::LimitNotices &limits) {
  const lua::Value bindings{state, -1, "plugin binding"};
  config::BindingKeymap keymap;
  config::BindingValidator::validate(bindings, validator, keymap, limits);
  const auto binding = bindings.element(1);
  const auto callback = binding.field("action");
  if (!callback.is(LUA_TFUNCTION) || binding.field("expression").boolean(false)) {
    callback.fail("must be an action callback");
  }

  callback.pushCopy();
  return luaL_ref(state, LUA_REGISTRYINDEX);
}

template <Allocator Memory>
void runPluginWorker(Memory &memory, const PluginWorkerOptions &options) {
  constexpr std::size_t maximum_source_bytes = std::size_t{1024} * 1024;
  const auto source = readFile(memory, options.entry, maximum_source_bytes);
  const auto directory = std::filesystem::canonical(std::filesystem::absolute(options.entry).parent_path()).string();
  lua::Vm vm{memory};
  vm.resetBudget();
  vm.execute(config::bootstrap, "@telar/bootstrap.lua", 0);
  lua_getglobal(vm.state(), "telar");
  lua::JsonDecoder<Memory>::install(vm.state(), memory);
  lua_pop(vm.state(), 1);
  config::LocalModules modules{vm.state(), directory};
  const auto wrapped = pluginCallbackSource(memory, source, options.action);
  config::LimitNotices limits;
  config::RetainedCommandTabRegistry commands;
  lua_pushnil(vm.state());
  const lua::Value empty{vm.state(), -1, "client"};
  const config::ClientDefinitions definitions{empty};
  const config::RetainedActionValidator validator{definitions, limits, commands};
  vm.execute(wrapped, "@plugin-worker.lua");
  const int reference = retainPluginCallback(vm.state(), validator, limits);
  lua_settop(vm.state(), 1);

  config::CallbackInvocation invocation{reference, options.context};
  constexpr std::uint64_t callback_instructions = 100'000;
  constexpr auto callback_deadline = std::chrono::milliseconds{100};
  vm.resetBudget(callback_instructions, callback_deadline);
  vm.invoke(&config::CallbackInvocation::invoke, &invocation, 1);
  const lua::Value result{vm.state(), -1, "plugin callback result"};
  plugins::ActionEncoder encoder{validator};
  const auto encoded = encoder.encode(result);

  // No bytes escape until the entire callback batch has passed validation.
  if (const int error = writeDescriptor(STDOUT_FILENO, encoded); error != 0) {
    throw SystemError{"Write plugin worker effects", error};
  }
}

}
}

// Interface: cli/redirect.cppm
export {
#if defined(__APPLE__)

namespace telar::runtime::cli {

template <Allocator Memory>
void runRedirect(Memory &memory, std::span<char *const> arguments, bool cleanup) {
  const char *socket = nullptr;
  std::array<redirect::Target, redirect::Target::maximum_targets> targets;
  std::size_t count = 0;
  std::array<ProcessIdentity, redirect::SocketOwners::maximum_processes> processes;
  std::size_t process_count = 0;
  bool dry_run = false;
  auto direction = redirect::Direction::outbound;
  bool direction_given = false;
  for (std::size_t index = 0; index < arguments.size(); ++index) {
    const std::string_view argument{arguments[index]};
    if (argument == "--dry-run" && !cleanup && !dry_run) {
      dry_run = true;
      continue;
    }
    if (index + 1 == arguments.size()) {
      throw std::invalid_argument{"Missing redirect option value"};
    }
    const std::string_view value{arguments[++index]};
    if (argument == "--socket" && socket == nullptr && !value.empty() && value.find_first_of("\r\n") == std::string_view::npos) {
      socket = arguments[index];
    } else if (argument == "--target" && !cleanup && count < targets.size()) {
      const auto target = redirect::Target::parse(value);
      if (std::ranges::any_of(std::span{targets}.first(count), [&](const auto &previous) { return previous.host.view() == target.host.view() && previous.port == target.port; })) {
        throw std::invalid_argument{"Duplicate redirect destination"};
      }
      targets[count++] = target;
    } else if (argument == "--direction" && !cleanup && !direction_given) {
      direction = redirect::parseDirection(value);
      direction_given = true;
    } else if (argument == "--process" && !cleanup && process_count < processes.size()) {
      const auto process = redirect::ProcessToken::parse(value);
      if (std::ranges::any_of(std::span{processes}.first(process_count), [&](const auto &other) { return other.pid == process.pid; })) { throw std::invalid_argument{"Duplicate selected process"}; }
      processes[process_count++] = process;
    } else {
      throw std::invalid_argument{"Unknown, duplicate or excessive redirect option"};
    }
  }
  if (!socket || (!cleanup && count == 0)) {
    throw std::invalid_argument{"Expected traffic redirect --socket PATH --target IP:PORT [--direction outbound|inbound|both] [--process PID[@SECONDS.MICROSECONDS]] [--dry-run]"};
  }
  String<Memory> endpoint{socket, AllocatorRef<char, Memory>{memory}};
  endpoint += redirect::socket_suffix;
  if (endpoint.front() != '/' || endpoint.size() >= sizeof(sockaddr_un::sun_path)) {
    throw std::invalid_argument{"Invalid absolute redirect endpoint"};
  }
  const redirect::PfIdentity identity{memory, endpoint};
  if (cleanup) {
    if (::geteuid() != 0) {
      throw std::invalid_argument{"Redirect recovery requires root"};
    }
    redirect::Record state{memory, identity, endpoint};
    redirect::PfCommand command{memory};
    redirect::PfLoopback interface{command};
    redirect::SharedLoopback loopback{memory, interface, identity.label};
    redirect::PfSession session{command, state, identity, loopback};
    session.recover();
    std::printf("telar redirect: recovered %s\n", identity.anchor.c_str());
    return;
  }
  if (!dry_run && ::geteuid() != 0) {
    throw std::invalid_argument{"Use sudo only for traffic redirect; keep the runtime unprivileged"};
  }
  redirect::Helper helper{memory, std::string_view{socket}, std::span{targets}.first(count), std::span{processes}.first(process_count), direction};
  if (dry_run) {
    struct stat metadata{};
    if (::lstat(endpoint.c_str(), &metadata) != 0 || !S_ISSOCK(metadata.st_mode) || (metadata.st_mode & 0077) != 0 || (::geteuid() != 0 && metadata.st_uid != ::geteuid())) {
      throw SystemError{"Enable runtime.proxy.transparent_redirect on an owned runtime first", EACCES};
    }
    if (process_count != 0) { const redirect::SocketOwners selected{metadata.st_uid, std::span{processes}.first(process_count)}; }
    const auto rules = helper.plan(metadata.st_uid, identity, true);
    redirect::PfCommand command{memory};
    const std::array<std::string_view, 5> arguments{"-n", "-a", identity.anchor, "-f", "-"};
    command.run(arguments, rules);
    std::fwrite(rules.data(), 1, rules.size(), stdout);
    return;
  }
  helper.run(identity);
}

}

#else

namespace telar::runtime::cli {

template <Allocator Memory>
void runRedirect(Memory &, std::span<char *const>, bool) {
  throw SystemError{"Transparent redirect requires a native Linux firewall adapter", ENOTSUP};
}

}
#endif
}

// Interface: cli/server.cppm
export {
namespace telar::runtime::cli {

template <ConcurrentAllocator Memory>
void runRuntime(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths, const config::RuntimeValues<Memory> &configuration) {
#if TELAR_DEBUG
  trace::Session tracing{memory, options.trace.empty() ? nullptr : options.trace.data()};
#endif
  const ExecutablePath executable;
  const ExecutablePath cli{"telar"};
  plugins::TapConfiguration tap_configuration{memory, configuration.configuration_directory.view(), configuration.plugins.configured(), process_environment};
  installPngDecoder();
  SqliteAllocator sqlite_memory{memory};
  std::optional<traffic::Service<Memory>> traffic_service;
  if (configuration.proxy.network_capture) {
    String<Memory> endpoint{paths.socket, AllocatorRef<char, Memory>{memory}};
    endpoint += traffic::socket_suffix;
    traffic_service.emplace(memory, endpoint, configuration.proxy.stream_interception);
  }
  plugins::Service plugin_service{memory, tap_configuration.specifications(), executable.c_str(), options.trace, traffic_service ? &*traffic_service : nullptr};
  if (!tap_configuration.specifications().empty()) { plugin_service.watchTrust(plugins::Paths::trust(memory, process_environment)); }

  traffic::Tap<Memory, plugins::Service<Memory>> tap{plugin_service, traffic_service ? &*traffic_service : nullptr};
  ProxyRuntime<Memory, NativeEventLoop<Memory>, SystemNameResolver, decltype(tap)> proxy{memory, configuration.proxy, paths.socket, configuration.proxy.enabled && paths.isDefaultSocket(process_environment), tap};
  traffic::control::Backend network_backend{memory, proxy, traffic_service ? &*traffic_service : nullptr, traffic::control::Configuration{
      .endpoint = paths.socket,
      .executable = executable.view(),
      .proxy = configuration.proxy.enabled,
      .redirect = configuration.proxy.transparent_redirect,
      .transparent_tls = configuration.proxy.transparent_tls,
      .interception = configuration.proxy.stream_interception,
      .administration = configuration.proxy.network_control,
  }};
  std::optional<traffic::control::Service<Memory, decltype(network_backend)>> network_control;
  if (traffic_service) {
    String<Memory> endpoint{paths.socket, AllocatorRef<char, Memory>{memory}};
    endpoint += traffic::control::socket_suffix;
    network_control.emplace(memory, endpoint, network_backend);
    traffic_service->packageControl(&*network_control);
  }
  // Queued halves borrow the proxy's capture quota, so workers must release them before the proxy is destroyed.
  plugins::ShutdownGuard stop_plugins{plugin_service};
  BackgroundService background_service{memory, paths.history.c_str(), configuration.history_filters};
  PathService path_service{memory};
  EditorService editor_service{memory};
  std::array<std::string_view, 32> engine_arguments;
  std::transform(configuration.engine.arguments.begin(), configuration.engine.arguments.end(), engine_arguments.begin(), [](const auto &argument) { return std::string_view{argument}; });
  const auto selected_arguments = options.engine_argument_count == 0 ? std::span<const std::string_view>{engine_arguments}.first(configuration.engine.arguments.size()) : std::span{options.engine_arguments}.first(options.engine_argument_count);
  SuggestionService suggestion_service{memory, SuggestionOptions{.arguments = selected_arguments, .timeout = configuration.engine.timeout, .idle_timeout = configuration.engine.idle_timeout}};
  std::array<std::string_view, 32> description_arguments;
  std::transform(configuration.descriptions.arguments.begin(), configuration.descriptions.arguments.end(), description_arguments.begin(), [](const auto &argument) { return std::string_view{argument}; });
  BackgroundPool background{memory, background_service, path_service, editor_service, suggestion_service};
  NativeEventLoop<Memory> poller{memory};
  poller.watchSignal(SIGTERM);
  poller.watchSignal(SIGINT);
  poller.watchSignal(SIGCHLD);
  Runtime runtime{memory, poller, background, RuntimeOptions{
                                                  .socket = paths.socket,
                                                  .cli_executable = cli.view(),
                                                  .session = {.path = paths.session, .resume_agents = options.resume_agents},
                                                  .fresh = options.fresh,
                                                  .capture_output = configuration.capture_output,
                                                  .manifests = &configuration.manifests,
                                                  .descriptions = {.arguments = std::span{description_arguments}.first(configuration.descriptions.arguments.size()), .timeout = configuration.descriptions.timeout},
                                                  .graphics = configuration.graphics,
                                                  .control_policy = configuration.control_policy,
                                              },
                  proxy.clientConfiguration()};
  runtime.run(proxy, plugin_service);
}

template <ConcurrentAllocator Memory>
void runServer(Memory &memory, const ServerOptions &options) {
  if (options.action == ServerAction::help) {
    std::puts("Usage: telar-runtime server [--socket PATH] [--no-config] [--fresh]\n       telar-runtime --socket PATH [--history PATH] [--session PATH | --no-session] [--no-resume]\n\n`telar server stop|endpoint|bridge` talks to a running runtime.");
    return;
  }
#if !TELAR_DEBUG
  if (!options.trace.empty()) {
    throw std::invalid_argument{"Tracing is available in Debug builds only"};
  }
#endif

  if (options.action != ServerAction::run) {
    throw std::invalid_argument{"telar-runtime only runs the runtime; use `telar server stop|endpoint|bridge`"};
  }

  const ProcessEnvironment environment;
  RuntimePaths paths{memory, options, environment};

  config::RuntimeValues configuration{memory};
  config::Loader{memory, configuration}.load(options, environment);
  configuration.limits.print();
  auto resolved_options = options;
  if (resolved_options.history.empty()) {
    resolved_options.history = configuration.history_path;
  }
  if (resolved_options.session.empty()) {
    resolved_options.session = configuration.session_path;
  }
  resolved_options.persist_session = options.persist_session && configuration.persist_session;
  resolved_options.resume_agents = options.resume_agents && configuration.resume_agents;

  paths.prepareSocket();
  if (options.mode == ServerMode::background) {
    launchDaemon(memory, options, paths, ExecutablePath{});
    return;
  }

  paths.resolveStorage(resolved_options, environment);
  paths.prepareStorage();
  runRuntime(memory, resolved_options, paths, configuration);
}

}
}

// Interface: cli/traffic.cppm
export {
namespace telar::runtime::cli {

template <Allocator Memory>
void runTraffic(Memory &memory, std::span<char *const> arguments) {
  if (arguments.size() == 1 && std::string_view{arguments[0]} == "--help") {
    std::puts("Usage: telar-runtime traffic capture --socket RUNTIME_SOCKET\n       telar-runtime traffic import --socket RUNTIME_SOCKET --file CAPTURE.pcap\n       telar-runtime traffic redirect --socket RUNTIME_SOCKET --target IP:PORT [--target [IPv6]:PORT] [--direction outbound|inbound|both] [--process PID] [--dry-run]\n       telar-runtime traffic redirect-cleanup --socket RUNTIME_SOCKET\n\nCapture/import require runtime.proxy.network_capture. Capture needs root; import is unprivileged.\nRedirect requires runtime.proxy.enabled and transparent_redirect. It selects local TCP connections\nfrom the runtime's user to numeric destinations, using a private PF anchor. Repeat --process to\nselect explicit account-owned PIDs; descendants are not implicit. --dry-run validates rules\nwithout applying them. Only capture/redirect/redirect-cleanup need root. TLS inspection is opt-in.");
    return;
  }
  if (arguments.empty()) {
    throw std::invalid_argument{"Expected traffic capture|import; use traffic --help"};
  }

  const std::string_view action{arguments.front()};
  if (action == "redirect" || action == "redirect-cleanup") {
    runRedirect(memory, arguments.subspan(1), action == "redirect-cleanup");
    return;
  }
  const char *socket = nullptr;
  const char *file = nullptr;
  for (std::size_t index = 1; index < arguments.size(); index += 2) {
    if (index + 1 == arguments.size()) {
      throw std::invalid_argument{"Missing traffic option value"};
    }
    const std::string_view option{arguments[index]};
    if (option == "--socket" && socket == nullptr) {
      socket = arguments[index + 1];
    } else if (option == "--file" && file == nullptr) {
      file = arguments[index + 1];
    } else {
      throw std::invalid_argument{"Unknown or duplicate traffic option"};
    }
  }
  if (socket == nullptr || (action != "capture" && action != "import") || ((action == "import") != (file != nullptr))) {
    throw std::invalid_argument{"Expected traffic capture --socket PATH or traffic import --socket PATH --file PCAP"};
  }

  String<Memory> path{socket, AllocatorRef<char, Memory>{memory}};
  path += traffic::socket_suffix;
  traffic::Capture capture{memory, traffic::connect(path)};
  if (file != nullptr) {
    capture.offline(file);
  } else {
    capture.live();
  }
}

}
}
