module telar.platform.paths;

import std;
import telar.tbc;
import telar.sys.posix;
import telar.platform.fs;
import telar.base.ds;

namespace telar::runtime {

  std::string_view ProcessEnvironment::lookup(const char* name) const noexcept {
    const auto* value = std::getenv(name); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment

    return value == nullptr ? std::string_view{} : std::string_view{value};
  }

  tbc::val_static<std::string_view> processHome() noexcept { // NOLINT(bugprone-exception-escape): only the copy's allocation throws, and a process without memory for it ends, as noexcept states
    // Copied once into storage of its own, which outlives every caller, as the environment it came
    // from may not once something replaces it.
    static SystemAllocator memory;
    [[clang::no_destroy]] static const ds::String<SystemAllocator> home{memory, process_environment.lookup("HOME")};

    return home.view();
  }

  void requireTracingBuild(bool requested) {
#if !TELAR_DEBUG
    if (requested) {
      throw std::invalid_argument{"Tracing is available in Debug builds only"};
    }
#else
    static_cast<void>(requested);
#endif
  }

}

namespace telar::runtime::cli {

  ServerOptions ServerOptions::parse(std::span<char* const> arguments) {
    ServerOptions options;
    bool action_selected = false;

    if (!arguments.empty() && std::string_view{arguments.front()} == "server") {
      arguments = arguments.subspan(1);
    }

    for (std::size_t index = 0; index < arguments.size(); ++index) {
      if (!options.applyValueOption(arguments, index)) {
        options.applyFlagOption(arguments[index], action_selected);
      }
    }

    if (options.fresh && options.action != ServerAction::run) {
      throw std::invalid_argument{"Fresh session requires the run action"};
    }

    if (options.action == ServerAction::stop && options.mode != ServerMode::foreground) {
      throw std::invalid_argument{"Conflicting server action"};
    }

    if (options.no_config && !options.profile.empty()) {
      throw std::invalid_argument{"A profile requires configuration"};
    }

    return options;
  }

  bool ServerOptions::applyValueOption(std::span<char* const> arguments, std::size_t& index) {
    const std::string_view argument = arguments[index];

    if (argument == "--socket") {
      setOnce(socket, nextValue(arguments, index));
    } else if (argument == "--history") {
      setOnce(history, nextValue(arguments, index));
    } else if (argument == "--session") {
      setOnce(session, nextValue(arguments, index));
    } else if (argument == "--trace") {
      setOnce(trace, nextValue(arguments, index));
    } else if (argument == "--config") {
      if (no_config) {
        throw std::invalid_argument{"Conflicting configuration options"};
      }

      setOnce(config, nextValue(arguments, index));
    } else if (argument == "--profile") {
      setOnce(profile, nextValue(arguments, index));
    } else if (argument == "--engine-arg") {
      if (engine_argument_count == engine_arguments.size()) {
        throw std::invalid_argument{"Too many engine arguments"};
      }

      engine_arguments.atMut(engine_argument_count++) = nextValue(arguments, index);
    } else {
      return false;
    }

    return true;
  }

  void ServerOptions::applyFlagOption(std::string_view argument, bool& action_selected) {
    if (argument == "stop" || argument == "endpoint" || argument == "bridge") {
      if (action_selected) {
        throw std::invalid_argument{"Duplicate server action"};
      }

      action_selected = true;
      if (argument == "stop") {
        action = ServerAction::stop;
      } else {
        action = argument == "endpoint" ? ServerAction::endpoint : ServerAction::bridge;
      }
    } else if (argument == "--help") {
      action = ServerAction::help;
    } else if (argument == "--no-session") {
      persist_session = false;
    } else if (argument == "--no-resume") {
      resume_agents = false;
    } else if (argument == "--no-config") {
      if (!config.empty()) {
        throw std::invalid_argument{"Conflicting configuration options"};
      }

      setFlag(no_config);
    } else if (argument == "--fresh") {
      setFlag(fresh);
    } else if (argument == "--background" || argument == "--daemonized") {
      if (mode != ServerMode::foreground) {
        throw std::invalid_argument{"Conflicting server modes"};
      }

      mode = argument == "--background" ? ServerMode::background : ServerMode::daemonized;
    } else {
      throw std::invalid_argument{"Unknown server option"};
    }
  }

  tbc::val_static<std::string_view> ServerOptions::nextValue(std::span<char* const> arguments, std::size_t& index) {
    if (++index == arguments.size()) {
      throw std::invalid_argument{"Missing server option value"};
    }

    // argv's strings live as long as the process.
    return std::string_view{tbc::raw(arguments[index])};
  }

  void ServerOptions::setOnce(std::string_view& destination, std::string_view value) {
    if (!destination.empty() || value.empty()) {
      throw std::invalid_argument{"Duplicate or empty server option"};
    }

    destination = value;
  }

  void ServerOptions::setFlag(bool& flag) {
    if (flag) {
      throw std::invalid_argument{"Duplicate server option"};
    }

    flag = true;
  }

  DefaultSocketEnvironment::DefaultSocketEnvironment(const EnvironmentSource& source) noexcept
      : source_(source) {}

  std::string_view DefaultSocketEnvironment::lookup(const char* name) const {
    const std::string_view key{name};

    return key == "TELAR_SOCKET" || key == "TELAR_SOCKET_PATH" ? std::string_view{} : source_.lookup(name);
  }

  tbc::val_a<XdgDirectory> findXdgDirectory(tbc::ref_a<EnvironmentSource> environment, const char* variable, tbc::val_a<std::string_view> fallback) {
    if (const auto base = environment.lookup(variable); base.starts_with('/')) {
      return {.base = base, .suffix = {}};
    }

    if (const auto home = environment.lookup("HOME"); home.starts_with('/')) {
      return {.base = home, .suffix = fallback};
    }

    return {};
  }

  template <Allocator Memory>
  tbc::val_a<ds::String<Memory>> xdgDirectory(tbc::mut_a<Memory> memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback) {
    const auto found = findXdgDirectory(environment, variable, fallback);
    ds::String<Memory> path{memory, found.base};

    path.append(found.suffix);
    return path;
  }

  template ds::String<Memory> xdgDirectory<Memory>(Memory& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);
  template ds::String<ConcurrentMemory> xdgDirectory<ConcurrentMemory>(ConcurrentMemory& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);
  template ds::String<SystemAllocator> xdgDirectory<SystemAllocator>(SystemAllocator& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);
  template ds::String<BudgetAllocator<SystemAllocator>> xdgDirectory<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>& memory, const EnvironmentSource& environment, const char* variable, std::string_view fallback);

  SocketLocation SocketLocation::resolve(std::string_view explicit_path, const EnvironmentSource& environment, std::uint32_t user) {
    for (const auto candidate : {explicit_path, environment.lookup("TELAR_SOCKET"), environment.lookup("TELAR_SOCKET_PATH")}) {
      if (!candidate.empty()) {
        return explicitPath(candidate);
      }
    }

    SocketLocation location;

    if (const auto runtime_directory = environment.lookup("XDG_RUNTIME_DIR"); !runtime_directory.empty()) {
      location.managed({.base = runtime_directory, .name = "telar"});
    } else {
      const auto temporary_directory = environment.lookup("TMPDIR");
      constexpr std::size_t name_bytes = 32;
      constexpr std::string_view prefix = "telar-";
      ds::Array<char, name_bytes> name{};

      std::ranges::copy(prefix, name.viewMut().begin());
      auto digits = name.viewMut().subspan(prefix.size());
      const auto converted = std::to_chars(digits.data(), std::to_address(digits.end()), user);

      location.managed({
          .base = temporary_directory.empty() ? "/tmp" : temporary_directory,
          .name = {name.data(), static_cast<std::size_t>(converted.ptr - name.data())},
      });
    }

    location.validate();
    return location;
  }

  SocketLocation SocketLocation::explicitPath(std::string_view path) {
    SocketLocation location;

    location.append(path);
    location.validate();
    return location;
  }

  std::string_view SocketLocation::path() const noexcept {
    return {bytes_.data(), length_};
  }

  ds::Option<std::string_view> SocketLocation::managedDirectory() const noexcept {
    return directory_ == 0 ? ds::none : ds::Option{std::string_view{bytes_.data(), directory_}};
  }

  void SocketLocation::managed(ManagedDirectory directory) {
    append(directory.base);
    if (!directory.base.ends_with('/')) {
      append("/");
    }

    append(directory.name);
    directory_ = length_;
    append("/runtime.sock");
  }

  void SocketLocation::append(std::string_view text) {
    if (text.size() >= bytes_.size() - length_) {
      throw std::invalid_argument{"Invalid absolute runtime socket path"};
    }

    std::ranges::copy(text, bytes_.viewMut().subspan(length_).begin());
    length_ += text.size();
  }

  void SocketLocation::validate() const {
    const auto socket = path();
    if (socket.empty() || socket.front() != '/' || socket.back() == '/' || socket.contains('\0')) {
      throw std::invalid_argument{"Invalid absolute runtime socket path"};
    }
  }

  template <Allocator Memory>
  RuntimePaths<Memory>::RuntimePaths(tbc::mut_a<Memory> memory, const ServerOptions& options, const EnvironmentSource& environment)
      : socket(memory),
        history(memory),
        session(memory),
        data_home(memory) {
    resolveSocket(options.socket, environment);
  }

  template <Allocator Memory>
  void RuntimePaths<Memory>::resolveStorage(const ServerOptions& options, const EnvironmentSource& environment) {
    data_home.assign(environment.lookup("XDG_DATA_HOME"));
    if (const auto home = environment.lookup("HOME"); data_home.empty() && !home.empty()) {
      data_home.assign(home);
      data_home.append("/.local/share");
    }

    history.assign(options.history.empty() ? environment.lookup("TELAR_HISTORY") : options.history);
    if (history.empty()) {
      if (data_home.empty()) {
        throw std::invalid_argument{"Home directory unavailable"};
      }

      history.assign(data_home);
      history.append("/telar/history.db");
      history_managed = true;
    }

    if (options.persist_session) {
      if (!options.session.empty()) {
        session.assign(options.session);
      } else {
        session.assign(std::string_view{history}.substr(0, history.view().find_last_of('/') + 1));
        session.append("session.ckpt");
      }
    }
  }

  template <Allocator Memory>
  void RuntimePaths<Memory>::prepareSocket() const {
    if (socket_managed) {
      createPrivateDirectory(std::string_view{socket}.substr(0, socket.view().rfind('/')));
    }
  }

  template <Allocator Memory>
  bool RuntimePaths<Memory>::isDefaultSocket(const EnvironmentSource& environment) const {
    const RuntimePaths expected{socket.memory(), ServerOptions(), DefaultSocketEnvironment{environment}};

    return socket == expected.socket;
  }

  template <Allocator Memory>
  tbc::val_a<ds::String<Memory>> RuntimePaths<Memory>::configHome(tbc::mut_a<Memory> memory, const EnvironmentSource& environment) {
    auto path = xdgDirectory(memory, environment, "XDG_CONFIG_HOME", "/.config");
    if (!path.empty()) {
      path.append("/telar");
    }

    return path;
  }

  template <Allocator Memory>
  tbc::val_a<ds::String<Memory>> RuntimePaths<Memory>::configFile(tbc::mut_a<Memory> memory, const EnvironmentSource& environment) {
    if (const auto development = environment.lookup("TELAR_DEVELOPMENT_CONFIG"); !development.empty()) {
      return ds::String<Memory>{memory, development};
    }

    auto path = configHome(memory, environment);
    if (!path.empty()) {
      path.append("/config.lua");
    }

    return path;
  }

  template <Allocator Memory>
  void RuntimePaths<Memory>::prepareStorage() const {
    if (history_managed) {
      createPrivateDirectory(std::string_view{history}.substr(0, history.view().rfind('/')));
    }
  }

  template <Allocator Memory>
  void RuntimePaths<Memory>::resolveSocket(std::string_view override, const EnvironmentSource& environment) {
    const auto location = SocketLocation::resolve(override, environment, ::getuid());

    socket.assign(location.path());
    socket_managed = location.managedDirectory().hasValue();
  }

  template class RuntimePaths<Memory>;
  template class RuntimePaths<ConcurrentMemory>;
  template class RuntimePaths<SystemAllocator>;
  template class RuntimePaths<BudgetAllocator<SystemAllocator>>;
  template class RuntimePaths<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
