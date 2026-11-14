module;
#include <lauxlib.h>
#include <lua.h>

module telar.runtime.cli.server;

import telar.sys.posix;
import telar.sys.socket;
import telar.sys.process;

import telar.lua;
import telar.platform.daemon;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.runtime.config.loader;
import telar.runtime.graphics.kitty;
import telar.runtime.history.event;
import telar.runtime.platform.background_executor;
import telar.runtime.plugins.service;
import telar.runtime.plugins.tap_configuration;
import telar.runtime.proxy.runtime;
import telar.runtime.runtime.delivery.client_delivery;
import telar.runtime.runtime.media_service;
import telar.runtime.runtime.runtime;
import telar.runtime.traffic.capture;
import telar.runtime.traffic.control_backend;
import :tap;
#ifdef __APPLE__
import telar.runtime.redirect.socket_owners;
#endif

namespace telar::runtime::cli {

  String<Memory> pluginCallbackSource(Memory& memory, std::string_view source, std::string_view action) {
    constexpr std::string_view prefix = "local telar = require(\"telar\")\nlocal plugin = (function()\n";
    constexpr std::string_view middle = "\nend)()\nif type(plugin) ~= \"table\" or type(plugin.actions) ~= \"table\" then error(\"plugin must return a table with an actions table\") end\nlocal callback = plugin.actions[\"";
    constexpr std::string_view suffix = "\"]\nif type(callback) ~= \"function\" then error(\"plugin action is not a function\") end\nreturn {telar.bind_global({\"escape\"}, callback)}";

    String<Memory> wrapped{AllocatorRef<char, Memory>{memory}};

    wrapped.reserve(prefix.size() + source.size() + middle.size() + action.size() + suffix.size());
    wrapped.append(prefix).append(source).append(middle).append(action).append(suffix);

    return wrapped;
  }

  int retainPluginCallback(lua_State* state, const config::RetainedActionValidator& validator, config::LimitNotices& limits) {
    const auto bindings = lua::Value{state, -1, "plugin binding"};
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

  void runPluginWorker(Memory& memory, const PluginWorkerOptions& options) {
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

#ifdef __APPLE__

  void runRedirect(Memory& memory, std::span<char* const> arguments, bool cleanup) {
    const char* socket = nullptr;
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

        if (std::ranges::any_of(std::span{targets}.first(count), [&](const auto& previous) {
              return previous.host.view() == target.host.view() && previous.port == target.port;
            })) {
          throw std::invalid_argument{"Duplicate redirect destination"};
        }

        targets[count++] = target;
      } else if (argument == "--direction" && !cleanup && !direction_given) {
        direction = redirect::parseDirection(value);
        direction_given = true;
      } else if (argument == "--process" && !cleanup && process_count < processes.size()) {
        const auto process = redirect::ProcessToken::parse(value);

        if (std::ranges::any_of(std::span{processes}.first(process_count), [&](const auto& other) {
              return other.pid == process.pid;
            })) {
          throw std::invalid_argument{"Duplicate selected process"};
        }

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
      std::println("telar redirect: recovered {}", identity.anchor.c_str());
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

      if (process_count != 0) {
        const redirect::SocketOwners selected{metadata.st_uid, std::span{processes}.first(process_count)};
      }

      const auto rules = helper.plan(metadata.st_uid, identity, true);
      redirect::PfCommand command{memory};
      const std::array<std::string_view, 5> arguments{"-n", "-a", identity.anchor, "-f", "-"};

      command.run(arguments, rules);
      std::fwrite(rules.data(), 1, rules.size(), stdout);
      return;
    }

    helper.run(identity);
  }

#else

  void runRedirect(Memory&, std::span<char* const>, bool) {
    throw SystemError{"Transparent redirect requires a native Linux firewall adapter", ENOTSUP};
  }

#endif

  void runRuntime(ConcurrentMemory& memory, const ServerOptions& options, const RuntimePaths<ConcurrentMemory>& paths, const config::RuntimeValues<ConcurrentMemory>& configuration) {
#if TELAR_DEBUG
    trace::Session tracing{memory, options.trace.empty() ? nullptr : options.trace.data()};
#endif
    const ExecutablePath executable;
    const ExecutablePath cli{"telar"};
    plugins::TapConfiguration tap_configuration{memory, configuration.configuration_directory.view(), configuration.plugins.configured(), process_environment};

    installPngDecoder();

    // Shells keep starting without the integration when its scripts cannot be written.
    String<ConcurrentMemory> shell_integration{AllocatorRef<char, ConcurrentMemory>{memory}};

    if (configuration.shell_integration && !paths.data_home.empty()) {
      try {
        shell_integration = ShellIntegration<ConcurrentMemory>::install(memory, paths.data_home);
      } catch (const SystemError& error) {
        std::fprintf(stderr, "telar runtime: shell integration disabled: %s\n", error.what());
      }
    }

    SqliteAllocator sqlite_memory{memory};
    std::optional<traffic::Service> traffic_service;

    if (configuration.proxy.network_capture) {
      String<ConcurrentMemory> endpoint{paths.socket, AllocatorRef<char, ConcurrentMemory>{memory}};

      endpoint += traffic::socket_suffix;
      traffic_service.emplace(memory, endpoint, configuration.proxy.stream_interception);
    }

    plugins::Service plugin_service{memory, tap_configuration.specifications(), executable.c_str(), options.trace, traffic_service ? &*traffic_service : nullptr};

    if (!tap_configuration.specifications().empty()) {
      plugin_service.watchTrust(plugins::Paths::trust(memory, process_environment));
    }

    traffic::Tap<plugins::Service> tap{plugin_service, traffic_service ? &*traffic_service : nullptr};
    ProxyRuntime<NativeEventLoop<ConcurrentMemory>, SystemNameResolver, decltype(tap)> proxy{memory, configuration.proxy, paths.socket, configuration.proxy.enabled && paths.isDefaultSocket(process_environment), tap};
    traffic::control::Backend network_backend{memory, proxy, traffic_service ? &*traffic_service : nullptr, traffic::control::Configuration{
                                                                                                                .endpoint = paths.socket,
                                                                                                                .executable = executable.view(),
                                                                                                                .proxy = configuration.proxy.enabled,
                                                                                                                .redirect = configuration.proxy.transparent_redirect,
                                                                                                                .transparent_tls = configuration.proxy.transparent_tls,
                                                                                                                .interception = configuration.proxy.stream_interception,
                                                                                                                .administration = configuration.proxy.network_control,
                                                                                                            }};

    std::optional<traffic::control::Service<ConcurrentMemory, decltype(network_backend)>> network_control;

    if (traffic_service) {
      String<ConcurrentMemory> endpoint{paths.socket, AllocatorRef<char, ConcurrentMemory>{memory}};

      endpoint += traffic::control::socket_suffix;
      network_control.emplace(memory, endpoint, network_backend);
      traffic_service->packageControl(&*network_control);
    }

    // Queued halves borrow the proxy's capture quota, so workers must release them before the proxy is destroyed.
    plugins::ShutdownGuard stop_plugins{plugin_service};
    BackgroundService background_service{memory, paths.history.c_str(), configuration.history_filters};
    PathService path_service{memory};
    EditorService editor_service{memory};
    const auto engine_arguments = configuration.engine.views();
    const auto selected_arguments = options.engine_argument_count == 0 ? engine_arguments.span() : std::span{options.engine_arguments}.first(options.engine_argument_count);
    SuggestionService suggestion_service{memory, SuggestionOptions{.arguments = selected_arguments, .timeout = configuration.engine.timeout, .idle_timeout = configuration.engine.idle_timeout}};
    const auto description_arguments = configuration.descriptions.views();
    BackgroundPool background{memory, background_service, path_service, editor_service, suggestion_service};
    NativeEventLoop<ConcurrentMemory> poller{memory};

    poller.watchSignal(SIGTERM);
    poller.watchSignal(SIGINT);
    poller.watchSignal(SIGCHLD);
    // Without a configuration file, completion specs still come from the configuration directory.
    const auto config_home = RuntimePaths<ConcurrentMemory>::configHome(memory, process_environment);
    const auto configuration_directory = configuration.configuration_directory.view();
    // The runtime keeps views of these options, so they live as long as it does.
    const RuntimeOptions runtime_options{
        .socket = paths.socket,
        .cli_executable = cli.view(),
        .session = {.path = paths.session, .resume_agents = options.resume_agents},
        .fresh = options.fresh,
        .capture_output = configuration.capture_output,
        .manifests = &configuration.manifests,
        .descriptions = {.arguments = description_arguments.span(), .timeout = configuration.descriptions.timeout},
        .graphics = configuration.graphics,
        .control_policy = configuration.control_policy,
        .shell_integration = shell_integration,
        .ssh_integration = configuration.ssh_integration,
        .configuration_directory = configuration_directory.empty() ? std::string_view{config_home} : configuration_directory,
    };

    Runtime runtime{memory, poller, background, runtime_options, proxy.clientConfiguration()};

    runtime.run(proxy, plugin_service);
  }

  void runServer(ConcurrentMemory& memory, const ServerOptions& options) {
    if (options.action == ServerAction::help) {
      std::puts("Usage: telar-runtime server [--socket PATH] [--no-config] [--fresh]\n       telar-runtime --socket PATH [--history PATH] [--session PATH | --no-session] [--no-resume]\n\n`telar server stop|endpoint|bridge` talks to a running runtime.");
      return;
    }

    requireTracingBuild(!options.trace.empty());

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

  void runTraffic(Memory& memory, std::span<char* const> arguments) {
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

    const char* socket = nullptr;
    const char* file = nullptr;

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
