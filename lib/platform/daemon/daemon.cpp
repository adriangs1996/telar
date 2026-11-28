module telar.platform.daemon;

import std;
import telar.sys.posix;
import telar.sys.process;
import telar.sys.socket;
import telar.platform.error;
import telar.base.ds;
import telar.tbc;

namespace telar::runtime::cli {

  FileDescriptor openStartLog(const char* path) noexcept {
    constexpr mode_t private_file_mode = 0600;
    FileDescriptor file{::open(path, combineFlags(O_WRONLY, O_CREAT, O_APPEND, O_NOFOLLOW, O_CLOEXEC, O_NONBLOCK), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat state{};
    const bool private_regular_file = file && ::fstat(file.get(), &state) == 0 && S_ISREG(state.st_mode) && state.st_uid == ::getuid() && state.st_nlink == 1;

    if (!private_regular_file || ::fchmod(file.get(), private_file_mode) != 0 || ::ftruncate(file.get(), 0) != 0) {
      file.reset();
    }

    return file;
  }

  pid_t spawnDaemon(const char* executable, char* const* arguments, const char* log_path) {
    const auto log = openStartLog(log_path);
    const FileDescriptor ignored{::open("/dev/null", combineFlags(O_RDWR, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!ignored) {
      throw SystemError{"Open daemon standard streams"};
    }

    SpawnOptions spawn{POSIX_SPAWN_SETSID};

    spawn.redirect(ignored.get(), STDIN_FILENO);
    spawn.redirect(ignored.get(), STDOUT_FILENO);
    spawn.redirect(log ? log.get() : ignored.get(), STDERR_FILENO);
    spawn.changeDirectory("/");
    spawn.closeOthers();
    pid_t child = -1;

    checkSpawn(::posix_spawn(&child, executable, &spawn.actions, &spawn.attributes, arguments, environ));
    return child;
  }

  template <Allocator Memory>
  pid_t launchDaemon(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths, const ExecutablePath& executable) {
    // Room for every argument but the engine's, which take two each.
    constexpr std::size_t other_arguments = 28;
    ds::Array<char, PATH_MAX> config_path{};
    ds::Vec<char*, Memory> arguments{memory};

    arguments.reserve((2 * options.engine_argument_count) + other_arguments);
    const auto append = [&](std::string_view value) {
      arguments.push(tbc::raw(const_cast<char*>(value.data()))); // NOLINT(cppcoreguidelines-pro-type-const-cast): posix_spawn's C signature takes the arguments as char*, and does not write them
    };

    append(executable.view());
    append("server");
    append("--daemonized");
    append("--socket");
    append(paths.socket);
    if (!options.history.empty()) {
      append("--history");
      append(options.history);
    }

    if (!options.session.empty()) {
      append("--session");
      append(options.session);
    }

    if (!options.trace.empty()) {
      append("--trace");
      append(options.trace);
    }

    if (!options.config.empty()) {
      if (::realpath(options.config.data(), config_path.dataMut()) == nullptr) {
        throw SystemError{"Resolve daemon configuration"};
      }

      append("--config");
      append(config_path.data());
    }

    if (!options.profile.empty()) {
      append("--profile");
      append(options.profile);
    }

    for (const auto argument : std::span{options.engine_arguments}.first(options.engine_argument_count)) {
      append("--engine-arg");
      append(argument);
    }

    for (const auto [enabled, flag] : ds::Array<std::pair<bool, std::string_view>, 4>{{{options.no_config, "--no-config"}, {options.fresh, "--fresh"}, {!options.persist_session, "--no-session"}, {!options.resume_agents, "--no-resume"}}}) {
      if (enabled) {
        append(flag);
      }
    }

    arguments.push(nullptr);
    ds::String<Memory> log_path{memory, paths.socket};

    log_path.append(".runtime.start.log");
    return spawnDaemon(executable.cStr(), arguments.data(), log_path.data());
  }

  template pid_t launchDaemon<Memory>(Memory&, const ServerOptions&, const RuntimePaths<Memory>&, const ExecutablePath&);
  template pid_t launchDaemon<ConcurrentMemory>(ConcurrentMemory&, const ServerOptions&, const RuntimePaths<ConcurrentMemory>&, const ExecutablePath&);
  template pid_t launchDaemon<SystemAllocator>(SystemAllocator&, const ServerOptions&, const RuntimePaths<SystemAllocator>&, const ExecutablePath&);
  template pid_t launchDaemon<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>&, const ServerOptions&, const RuntimePaths<BudgetAllocator<SystemAllocator>>&, const ExecutablePath&);
  template pid_t launchDaemon<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>&, const ServerOptions&, const RuntimePaths<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>&, const ExecutablePath&);

}
