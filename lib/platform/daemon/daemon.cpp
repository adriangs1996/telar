module telar.platform.daemon;

import std;
import telar.sys.posix;
import telar.sys.process;
import telar.sys.socket;
import telar.platform.error;
import telar.base.ds;

namespace telar::runtime::cli {

  FileDescriptor openStartLog(const char* path) noexcept {
    FileDescriptor file{::open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::getuid() || state.st_nlink != 1) {
      return FileDescriptor{};
    }

    if (::fchmod(file.get(), 0600) != 0 || ::ftruncate(file.get(), 0) != 0) {
      return FileDescriptor{};
    }

    return file;
  }

  pid_t spawnDaemon(const char* executable, char* const* arguments, const char* log_path) {
    auto log = openStartLog(log_path);
    FileDescriptor ignored{::open("/dev/null", O_RDWR | O_CLOEXEC)};
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
    ds::Array<char, PATH_MAX> config_path;
    Vector<char*, Memory> arguments{AllocatorRef<char*, Memory>{memory}};

    arguments.reserve(2 * options.engine_argument_count + 28);
    const auto append = [&](std::string_view value) {
      arguments.push_back(const_cast<char*>(value.data()));
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

    arguments.push_back(nullptr);
    String<Memory> log_path{paths.socket, AllocatorRef<char, Memory>{memory}};

    log_path += ".runtime.start.log";
    return spawnDaemon(executable.c_str(), arguments.data(), log_path.c_str());
  }

  template pid_t launchDaemon<Memory>(Memory&, const ServerOptions&, const RuntimePaths<Memory>&, const ExecutablePath&);
  template pid_t launchDaemon<ConcurrentMemory>(ConcurrentMemory&, const ServerOptions&, const RuntimePaths<ConcurrentMemory>&, const ExecutablePath&);
  template pid_t launchDaemon<SystemAllocator>(SystemAllocator&, const ServerOptions&, const RuntimePaths<SystemAllocator>&, const ExecutablePath&);
  template pid_t launchDaemon<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>&, const ServerOptions&, const RuntimePaths<BudgetAllocator<SystemAllocator>>&, const ExecutablePath&);
  template pid_t launchDaemon<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>&, const ServerOptions&, const RuntimePaths<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>&, const ExecutablePath&);

}
