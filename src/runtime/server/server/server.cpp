module telar.runtime.server.server;

import telar.tbc;
import telar.sys.posix;
import telar.sys.socket;
import telar.sys.process;

import telar.lua;
import telar.platform.daemon;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.runtime.server.config.loader;
import telar.runtime.terminal.kitty;
import telar.runtime.history.event;
import telar.runtime.workers.background_executor;
import telar.runtime.plugins.service;
import telar.runtime.plugins.tap_configuration;
import telar.runtime.traffic.proxy.runtime;
import telar.runtime.core.delivery.client_delivery;
import telar.runtime.core.media_service;
import telar.runtime.core.runtime;
import telar.runtime.traffic.capture;
import telar.runtime.traffic.control_backend;
import :tap;
import telar.plugins;
import telar.runtime.host.event_loop;
import telar.runtime.terminal.shell_integration;
import telar.runtime.traffic.tap.protocol;
import telar.runtime.suggestions.engine;
import telar.runtime.host.name_resolutions;
import telar.base.ds;
#ifdef __APPLE__
import telar.runtime.traffic.redirect.socket_owners;
import telar.runtime.host.process_probe;
import telar.runtime.traffic.redirect.direction;
import telar.runtime.traffic.redirect.ingress;
import telar.runtime.traffic.redirect.record;
import telar.runtime.traffic.redirect.pf_rules;
#endif

namespace telar::runtime::cli {

  tbc::val_a<ds::String<Memory>> pluginCallbackSource(tbc::mut_a<Memory> memory, std::string_view source, std::string_view action) {
    constexpr std::string_view prefix = "local telar = require(\"telar\")\nlocal plugin = (function()\n";
    constexpr std::string_view middle = "\nend)()\nif type(plugin) ~= \"table\" or type(plugin.actions) ~= \"table\" then error(\"plugin must return a table with an actions table\") end\nlocal callback = plugin.actions[\"";
    constexpr std::string_view suffix = "\"]\nif type(callback) ~= \"function\" then error(\"plugin action is not a function\") end\nreturn {telar.bind_global({\"escape\"}, callback)}";

    ds::String<Memory> wrapped{memory};

    wrapped.reserve(prefix.size() + source.size() + middle.size() + action.size() + suffix.size());
    for (const auto part : {prefix, source, middle, action, suffix}) {
      wrapped.append(part);
    }

    return wrapped;
  }

  int retainPluginCallback(lua_State* state, config::RetainedActionValidator& validator, config::LimitNotices& limits) {
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

    lua::Vm machine{memory};

    machine.resetBudget();
    machine.execute(config::bootstrap, "@telar/bootstrap.lua", 0);
    lua_getglobal(machine.state(), "telar");
    lua::JsonDecoder<Memory>::install(machine.state(), memory);
    lua_pop(machine.state(), 1);
    const config::LocalModules modules{machine.state(), directory};
    const auto wrapped = pluginCallbackSource(memory, source, options.action);
    config::LimitNotices limits;
    config::LimitNotices binding_limits;
    config::RetainedCommandTabRegistry commands;

    lua_pushnil(machine.state());
    const lua::Value empty{machine.state(), -1, "client"};
    const config::ClientDefinitions definitions{empty};
    config::RetainedActionValidator validator{definitions, limits, commands};

    machine.execute(wrapped, "@plugin-worker.lua");
    const int reference = retainPluginCallback(machine.state(), validator, binding_limits);

    lua_settop(machine.state(), 1);

    config::CallbackInvocation invocation{reference, options.context};
    constexpr std::uint64_t callback_instructions = 100'000;
    constexpr auto callback_deadline = std::chrono::milliseconds{100};

    machine.resetBudget(callback_instructions, callback_deadline);
    machine.invoke(&config::CallbackInvocation::invoke, &invocation, 1);
    const lua::Value result{machine.state(), -1, "plugin callback result"};
    plugins::ActionEncoder encoder{validator};
    const auto encoded = encoder.encode(result);

    // No bytes escape until the entire callback batch has passed validation.
    if (const int error = writeDescriptor(STDOUT_FILENO, encoded); error != 0) {
      throw SystemError{"Write plugin worker effects", error};
    }
  }

#ifdef __APPLE__

  namespace {

    // What `traffic redirect` was asked: the runtime's socket, the destinations and processes it
    // redirects, in which direction, and whether only to show the rules.
    struct RedirectOptions {
      const char* socket = nullptr;
      ds::Array<redirect::Target, redirect::Target::maximum_targets> targets;
      std::size_t count = 0;
      ds::Array<ProcessIdentity, redirect::SocketOwners::maximum_processes> processes;
      std::size_t process_count = 0;
      bool dry_run = false;
      redirect::Direction direction = redirect::Direction::outbound;
      bool direction_given = false;
    };

    void addRedirectTarget(RedirectOptions& options, std::string_view value) {
      const auto target = redirect::Target::parse(value);

      if (std::ranges::any_of(std::span{options.targets}.first(options.count), [&](const auto& previous) {
            return previous.host.view() == target.host.view() && previous.port == target.port;
          })) {
        throw std::invalid_argument{"Duplicate redirect destination"};
      }

      options.targets.atMut(options.count++) = target;
    }

    void addRedirectProcess(RedirectOptions& options, std::string_view value) {
      const auto process = redirect::ProcessToken::parse(value);

      if (std::ranges::any_of(std::span{options.processes}.first(options.process_count), [&](const auto& other) {
            return other.pid == process.pid;
          })) {
        throw std::invalid_argument{"Duplicate selected process"};
      }

      options.processes.atMut(options.process_count++) = process;
    }

    // Reads one option that takes a value; the options keep the socket's text, region `a`.
    void redirectOption(tbc::mut_a<RedirectOptions> options, std::string_view argument, tbc::val_a<const char*> value_text, bool cleanup) {
      const std::string_view value{value_text};

      if (argument == "--socket" && options.socket == nullptr && !value.empty() && value.find_first_of("\r\n") == std::string_view::npos) {
        options.socket = value_text;
      } else if (argument == "--target" && !cleanup && options.count < options.targets.size()) {
        addRedirectTarget(options, value);
      } else if (argument == "--direction" && !cleanup && !options.direction_given) {
        options.direction = redirect::parseDirection(value);
        options.direction_given = true;
      } else if (argument == "--process" && !cleanup && options.process_count < options.processes.size()) {
        addRedirectProcess(options, value);
      } else {
        throw std::invalid_argument{"Unknown, duplicate or excessive redirect option"};
      }
    }

    RedirectOptions redirectOptions(std::span<char* const> arguments, bool cleanup) {
      RedirectOptions options;

      for (std::size_t index = 0; index < arguments.size(); ++index) {
        const std::string_view argument{arguments[index]};

        if (argument == "--dry-run" && !cleanup && !options.dry_run) {
          options.dry_run = true;
          continue;
        }

        if (index + 1 == arguments.size()) {
          throw std::invalid_argument{"Missing redirect option value"};
        }

        redirectOption(options, argument, arguments[++index], cleanup);
      }

      return options;
    }

    // Removes the rules and the loopback alias a redirect that did not stop left behind.
    void recoverRedirect(Memory& memory, const redirect::PfIdentity<Memory>& identity, const ds::String<Memory>& endpoint) {
      using Loopback = redirect::SharedLoopback<Memory, redirect::PfLoopback<redirect::PfCommand>>;

      if (::geteuid() != 0) {
        throw std::invalid_argument{"Redirect recovery requires root"};
      }

      redirect::Record<Memory> state{memory, identity, endpoint};
      redirect::PfCommand command{memory};
      redirect::PfLoopback<redirect::PfCommand> interface{command};
      Loopback loopback{memory, interface, identity.label};
      redirect::PfSession<redirect::PfCommand, redirect::Record<Memory>, Loopback, Memory> session{command, state, identity, loopback};

      session.recover();
      std::println("telar redirect: recovered {}", identity.anchor.data());
    }

    // Checks the rules a redirect would load, without loading them, and prints them.
    void planRedirect(Memory& memory, const redirect::Helper& helper, const redirect::PfIdentity<Memory>& identity, const ds::String<Memory>& endpoint, std::span<const ProcessIdentity> processes) {
      // Only its owner may reach the runtime's socket.
      constexpr mode_t shared_access = 0077;
      struct stat metadata{};

      if (::lstat(endpoint.data(), &metadata) != 0 || !S_ISSOCK(metadata.st_mode) || (metadata.st_mode & shared_access) != 0 || (::geteuid() != 0 && metadata.st_uid != ::geteuid())) {
        throw SystemError{"Enable runtime.proxy.transparent_redirect on an owned runtime first", EACCES};
      }

      if (!processes.empty()) {
        const redirect::SocketOwners selected{metadata.st_uid, processes};
      }

      const auto rules = helper.plan(metadata.st_uid, identity, true);
      redirect::PfCommand command{memory};
      const ds::Array<std::string_view, 5> pf_arguments{"-n", "-a", identity.anchor, "-f", "-"};

      command.run(pf_arguments, rules);
      std::print("{}", std::string_view{rules});
    }

  }

  void runRedirect(Memory& memory, std::span<char* const> arguments, bool cleanup) {
    const auto options = redirectOptions(arguments, cleanup);

    if ((options.socket == nullptr) || (!cleanup && options.count == 0)) {
      throw std::invalid_argument{"Expected traffic redirect --socket PATH --target IP:PORT [--direction outbound|inbound|both] [--process PID[@SECONDS.MICROSECONDS]] [--dry-run]"};
    }

    ds::String<Memory> endpoint{memory, options.socket};

    endpoint.append(redirect::socket_suffix);

    if (endpoint.view().front() != '/' || endpoint.size() >= sizeof(sockaddr_un::sun_path)) {
      throw std::invalid_argument{"Invalid absolute redirect endpoint"};
    }

    const redirect::PfIdentity<Memory> identity{memory, endpoint};

    if (cleanup) {
      recoverRedirect(memory, identity, endpoint);
      return;
    }

    if (!options.dry_run && ::geteuid() != 0) {
      throw std::invalid_argument{"Use sudo only for traffic redirect; keep the runtime unprivileged"};
    }

    const auto processes = std::span{options.processes}.first(options.process_count);
    redirect::Helper helper{memory, std::string_view{options.socket}, std::span{options.targets}.first(options.count), processes, options.direction};

    if (options.dry_run) {
      planRedirect(memory, helper, identity, endpoint, processes);
      return;
    }

    helper.run(identity);
  }

#else

  void runRedirect(Memory&, std::span<char* const>, bool) {
    throw SystemError{"Transparent redirect requires a native Linux firewall adapter", ENOTSUP};
  }

#endif

  namespace {

    // Installs the scripts of the shell integration when the configuration asks for it, and
    // says where. Shells keep starting without the integration when they cannot be written.
    tbc::val_a<ds::String<ConcurrentMemory>> installShellIntegration(tbc::mut_a<ConcurrentMemory> memory, const RuntimePaths<ConcurrentMemory>& paths, bool wanted) {
      ds::String<ConcurrentMemory> installed{memory};

      if (wanted && !paths.data_home.empty()) {
        try {
          installed = ShellIntegration<ConcurrentMemory>::install(memory, paths.data_home);
        } catch (const SystemError& error) {
          std::println(stderr, "telar runtime: shell integration disabled: {}", error.what());
        }
      }

      return installed;
    }

    // Where the editor's Neovim reads its configuration, whatever file configured telar; empty
    // without a home for configurations.
    tbc::val_a<ds::String<ConcurrentMemory>> editorConfiguration(tbc::mut_a<ConcurrentMemory> memory, std::string_view config_home) {
      ds::String<ConcurrentMemory> directory{memory};

      if (!config_home.empty()) {
        directory.assign(config_home);
        directory.append("/editor");
      }

      return directory;
    }

  }

  void runRuntime(ConcurrentMemory& memory, const ServerOptions& options, const RuntimePaths<ConcurrentMemory>& paths, const config::RuntimeValues<ConcurrentMemory>& configuration) {
#if TELAR_DEBUG
    const trace::Session tracing{memory, options.trace.empty() ? nullptr : options.trace.data()};
#endif
    const ExecutablePath executable;
    const ExecutablePath cli{"telar"};
    const plugins::TapConfiguration tap_configuration{memory, configuration.configuration_directory.view(), configuration.plugins.configured(), process_environment};

    installPngDecoder();

    const auto shell_integration = installShellIntegration(memory, paths, configuration.shell_integration);
    const SqliteAllocator sqlite_memory{memory};
    ds::Option<traffic::Service> traffic_service;

    if (configuration.proxy.network_capture) {
      ds::String<ConcurrentMemory> endpoint{memory, paths.socket};

      endpoint.append(traffic::socket_suffix);
      traffic_service.emplace(memory, endpoint, configuration.proxy.stream_interception);
    }

    // The plugins, the tap and the control backend share the one traffic service.
    auto* const shared_traffic = traffic_service ? &traffic_service.getMut() : nullptr;

    plugins::Service plugin_service{memory, tap_configuration.specifications(), executable.cStr(), options.trace, shared_traffic};

    if (!tap_configuration.specifications().empty()) {
      plugin_service.watchTrust(plugins::Paths::trust(memory, process_environment));
    }

    traffic::Tap<plugins::Service> tap{plugin_service, shared_traffic};
    ProxyRuntime<NativeEventLoop<ConcurrentMemory>, SystemNameResolver, decltype(tap)> proxy{memory, configuration.proxy, paths.socket, configuration.proxy.enabled && paths.isDefaultSocket(process_environment), tap};
    traffic::control::Backend<decltype(proxy)> network_backend{memory, proxy, shared_traffic, traffic::control::Configuration{
                                                                                                  .endpoint = paths.socket,
                                                                                                  .executable = executable.view(),
                                                                                                  .proxy = configuration.proxy.enabled,
                                                                                                  .redirect = configuration.proxy.transparent_redirect,
                                                                                                  .transparent_tls = configuration.proxy.transparent_tls,
                                                                                                  .interception = configuration.proxy.stream_interception,
                                                                                                  .administration = configuration.proxy.network_control,
                                                                                              }};

    ds::Option<traffic::control::Service<ConcurrentMemory, decltype(network_backend)>> network_control;

    if (shared_traffic != nullptr) {
      ds::String<ConcurrentMemory> endpoint{memory, paths.socket};

      endpoint.append(traffic::control::socket_suffix);
      network_control.emplace(memory, endpoint, network_backend);
      shared_traffic->packageControl(&network_control.getMut());
    }

    // Queued halves borrow the proxy's capture quota, so workers must release them before the proxy is destroyed.
    const plugins::ShutdownGuard stop_plugins{plugin_service};
    BackgroundService background_service{memory, paths.history.data(), configuration.history_filters};
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
    const auto editor_configuration = editorConfiguration(memory, config_home.view());

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
        .data_home = paths.data_home,
        .ssh_integration = configuration.ssh_integration,
        .agent_plans = configuration.agent_plans,
        .configuration_directory = configuration_directory.empty() ? std::string_view{config_home} : configuration_directory,
        .editor_configuration = editor_configuration.view(),
    };

    Runtime runtime{memory, poller, background, runtime_options, proxy.clientConfiguration()};

    runtime.run(proxy, plugin_service);
  }

  void runServer(ConcurrentMemory& memory, const ServerOptions& options) {
    if (options.action == ServerAction::help) {
      std::puts("Usage: telar-runtime server [--socket PATH] [--no-config] [--fresh]\n       telar-runtime --socket PATH [--history PATH] [--session PATH | --no-session] [--no-resume]\n\n`telar server stop|endpoint` talks to a running runtime.");
      return;
    }

    requireTracingBuild(!options.trace.empty());

    if (options.action != ServerAction::run) {
      throw std::invalid_argument{"telar-runtime only runs the runtime; use `telar server stop|endpoint`"};
    }

    const ProcessEnvironment environment;
    RuntimePaths<ConcurrentMemory> paths{memory, options, environment};

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

    ds::String<Memory> path{memory, socket};

    path.append(traffic::socket_suffix);
    traffic::Capture capture{memory, traffic::connect(path)};

    if (file != nullptr) {
      capture.offline(file);
    } else {
      capture.live();
    }
  }

}
