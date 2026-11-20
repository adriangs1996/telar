module telar.platform.process;

import std;
import telar.sys.posix;
import telar.tbc;
import telar.sys.process;
import telar.platform.error;
import telar.base.ds;
import telar.base.text;
import telar.platform.net;
#ifdef __APPLE__
import telar.sys.apple;
#endif
#ifdef __linux__
import telar.sys.linux_api;
#endif

namespace telar::runtime {
  namespace {

    using Clock = std::chrono::steady_clock;

    // The streams a command's loop waits on, polled until one is ready or the deadline is near:
    // its output, its errors and its input, in that order.
    ds::Array<pollfd, 3> pollStreams(const PipeProcess& process, Clock::time_point deadline) {
      constexpr std::int64_t longest_wait_milliseconds = 20;
      ds::Array descriptors{
          pollfd{.fd = process.output(), .events = POLLIN, .revents = 0},
          pollfd{.fd = process.error(), .events = POLLIN, .revents = 0},
          pollfd{.fd = process.input(), .events = POLLOUT, .revents = 0},
      };

      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
      const int result = ::poll(descriptors.dataMut(), descriptors.size(), static_cast<int>(std::clamp<std::int64_t>(remaining, 0, longest_wait_milliseconds)));

      if (result < 0 && sys::lastError() != EINTR) {
        throw SystemError{"Wait for command output"};
      }

      return descriptors;
    }

    // Hands what the ready output and error streams hold to their consumers and closes a stream
    // that ended; false when the output consumer asks to stop.
    bool readStreams(PipeProcess& process, const ds::Array<pollfd, 3>& descriptors, std::span<Byte> buffer, BytesConsumer consume, const BytesConsumer* consume_error) {
      for (std::size_t index = 0; index < 2; ++index) {
        if (descriptors[index].fd < 0 || descriptors[index].revents == 0) {
          continue;
        }

        const auto count = ::read(descriptors[index].fd, buffer.data(), buffer.size());
        if (count > 0) {
          const auto bytes = std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count));
          if (index == 0 && !consume(bytes)) {
            return false;
          }

          if (index == 1 && consume_error != nullptr) {
            (*consume_error)(bytes);
          }
        } else if (count == 0) {
          if (index == 0) {
            process.closeOutput();
          } else {
            process.closeError();
          }
        } else if (!socketWouldBlock(sys::lastError())) {
          throw SystemError{"Read command output"};
        }
      }

      return true;
    }

  }

  bool findExecutable(ExecutableSearch search, std::span<char, PATH_MAX> found) noexcept {
    auto path = search.path;
    const auto program = search.program;
    const auto cwd = search.cwd;

    for (;;) {
      const auto separator = path.find(':');
      const auto directory = separator == std::string_view::npos ? path : std::string_view{path.data(), separator};
      const bool relative = directory.empty() || directory.front() != '/';
      std::string_view base;

      if (relative) {
        base = cwd.empty() ? std::string_view{"."} : cwd;
      }

      const auto length = base.size() + (relative ? 1 : 0) + directory.size() + 1 + program.size();
      if (length < found.size()) {
        std::size_t written = 0;
        const auto write = [&](std::string_view text) {
          std::ranges::copy(text, found.subspan(written).begin());
          written += text.size();
        };

        write(base);
        if (relative) {
          write("/");
        }

        write(directory);
        write("/");
        write(program);
        found[written] = '\0';
        if (::access(found.data(), X_OK) == 0) {
          return true;
        }
      }

      if (separator == std::string_view::npos) {
        return false;
      }

      path.remove_prefix(separator + 1);
    }
  }

  template <Allocator Memory>
  Command<Memory>::Command(tbc::mut_a<Memory> memory, const Launch& launch, CommandPurpose purpose)
      : executable_(memory),
        cwd_(memory, launch.cwd),
        arguments_(memory),
        spawn_arguments_(memory),
        environment_memory_(memory),
        environment_(environment_memory_),
        argument_pointers_(memory),
        environment_pointers_(memory),
        memory_(memory),
        restorable_(launch.environment_mode == EnvironmentMode::inherit_runtime) {
    if (cwd_.empty()) {
      ds::Array<char, PATH_MAX> current{};
      if (::getcwd(current.dataMut(), current.size()) == nullptr) {
        throw SystemError{"resolve working directory"};
      }

      cwd_.assign(current.data());
    }

    for (const auto argument : launch.arguments) {
      arguments_.emplace(memory, argument);
    }

    if (arguments_.empty()) {
      arguments_.emplace(memory, loginShell().view());
    }

    if (launch.environment_mode == EnvironmentMode::inherit_runtime) {
      for (char** entry = environ; *entry != nullptr; ++entry) { // NOLINT(clang-diagnostic-unsafe-buffer-usage): environ is a C array whose end only its null entry marks
        environment_.emplace(environment_memory_, *entry);
      }
    }

    for (const auto& entry : launch.environment) {
      setEnvironment(entry);
    }

    const auto drops = [purpose](const auto& entry) {
      if (purpose == CommandPurpose::configured_helper) {
        return false;
      }

      const auto name = std::string_view{entry}.substr(0, entry.view().find('='));

      if (purpose == CommandPurpose::administration) {
        return name == "TELAR_PANE_ID" || name == "TELAR_PANE_GENERATION" || name == "TELAR_WORKSPACE_ID" || name == "TELAR_TAB_ID" || name == "SSH_AUTH_SOCK";
      }

      return name == "GHOSTTY_RESOURCES_DIR" || name == "TELAR_SOCKET" || name == "TERM_PROGRAM_VERSION";
    };

    static_cast<void>(environment_.retain([&drops](const auto& entry) {
      return !drops(entry);
    }));

    if (purpose == CommandPurpose::terminal) {
      setEnvironment({.name = "TERM_PROGRAM", .value = control::program_name});
      setEnvironment({.name = "TERM_PROGRAM_VERSION", .value = control::program_version});
      setEnvironment({.name = "TELAR_TERM_PROGRAM", .value = "telar"});
      setEnvironment({.name = "TERM", .value = "xterm-256color"});
      setEnvironment({.name = "COLORTERM", .value = "truecolor"});
    }

    resolveExecutable();
  }

  template <Allocator Memory>
  void Command<Memory>::removeEnvironmentPrefix(std::string_view prefix) {
    static_cast<void>(environment_.retain([prefix](const auto& entry) {
      return !entry.view().starts_with(prefix);
    }));
  }

  template <Allocator Memory>
  ds::Option<std::string_view> Command<Memory>::environment(std::string_view name) const noexcept {
    for (const auto& entry : environment_) {
      if (definesVariable(entry, name)) {
        std::string_view value{entry};

        value.remove_prefix(name.size() + 1);
        return value;
      }
    }

    return ds::none;
  }

  template <Allocator Memory>
  void Command<Memory>::removeEnvironment(std::string_view name) {
    // The value may be a secret: its bytes are erased in place before the entry goes. An entry is
    // never empty, `NAME=value`, so an erased one is told by its emptiness.
    for (auto& entry : environment_.viewMut()) {
      if (definesVariable(entry, name)) {
        eraseSensitive(entry.dataMut(), entry.size());
        entry.clear();
      }
    }

    static_cast<void>(environment_.retain([](const auto& entry) {
      return !entry.empty();
    }));
  }

  template <Allocator Memory>
  void Command<Memory>::replaceSpawnArguments(std::span<const std::string_view> arguments) {
    spawn_arguments_.clear();
    for (const auto argument : arguments) {
      spawn_arguments_.emplace(memory_, argument);
    }
  }

  template <Allocator Memory>
  void Command<Memory>::setEnvironment(EnvironmentEntry variable) {
    const auto name = variable.name;
    ds::String<SensitiveMemory> entry{environment_memory_, name};

    entry.push('=');
    entry.append(variable.value);

    for (auto& existing : environment_.viewMut()) {
      const auto separator = existing.view().find('=');
      if (std::string_view{existing}.substr(0, separator) == name) {
        eraseSensitive(existing.dataMut(), existing.size());
        existing = std::move(entry);
        return;
      }
    }

    environment_.push(std::move(entry));
  }

  template <Allocator Memory>
  SpawnSpec Command<Memory>::specification(TerminalSize size) {
    argument_pointers_.clear();
    environment_pointers_.clear();

    argument_pointers_.push(arguments_.front().data());
    const auto rest = spawn_arguments_.empty() ? arguments_.view().subspan(1) : spawn_arguments_.view();

    for (const auto& argument : rest) {
      argument_pointers_.push(argument.data());
    }

    for (const auto& entry : environment_.view()) {
      environment_pointers_.push(entry.data());
    }

    argument_pointers_.push(nullptr);
    environment_pointers_.push(nullptr);
    return SpawnSpec{
        .executable = executable_.data(),
        .cwd = cwd_.data(),
        // POSIX declares argv and envp `char* const[]` for C's sake and never writes them.
        .arguments = const_cast<char* const*>(argument_pointers_.data()),
        .environment = const_cast<char* const*>(environment_pointers_.data()),
        .size = size,
    };
  }

  template <Allocator Memory>
  std::string_view Command<Memory>::cwd() const noexcept {
    return cwd_;
  }

  template <Allocator Memory>
  std::span<const ds::String<Memory>> Command<Memory>::arguments() const noexcept {
    return arguments_;
  }

  template <Allocator Memory>
  bool Command<Memory>::restorable() const noexcept {
    return restorable_;
  }

  template <Allocator Memory>
  bool Command<Memory>::definesVariable(std::string_view entry, std::string_view name) noexcept {
    return entry.size() > name.size() && entry[name.size()] == '=' && entry.starts_with(name);
  }

  template <Allocator Memory>
  void Command<Memory>::resolveExecutable() {
    const auto& program = arguments_.front();
    if (program.view().find('/') != std::string_view::npos) {
      executable_.assign(program);
      return;
    }

    constexpr std::string_view path_entry = "PATH=";
    std::string_view path = "/usr/bin:/bin";

    for (const auto& entry : environment_) {
      if (std::string_view{entry}.starts_with(path_entry)) {
        path = std::string_view{entry}.substr(path_entry.size());
        break;
      }
    }

    ds::Array<char, PATH_MAX> found{};
    if (!findExecutable({.path = path, .program = program, .cwd = cwd()}, found.viewMut())) {
      throw SystemError{"resolve pane executable", ENOENT};
    }

    executable_.assign(found.data());
  }

  bool BytesConsumer::operator()(std::span<const Byte> bytes) const {
    return consume_(consumer_, bytes);
  }

  template <Allocator Memory>
  CommandOutput<Memory>::CommandOutput(Memory& memory, std::size_t limit, const std::atomic<bool>* cancelled)
      : output_(memory, limit),
        limit_(limit),
        cancelled_(cancelled) {}

  template <Allocator Memory>
  int CommandOutput<Memory>::run(Command<Memory>& command, Clock::time_point deadline, bool retain_prefix, const std::atomic<bool>* cancelled) {
    return execute(command, deadline, ExecutionOptions{.cancelled = cancelled}, [&](std::span<const Byte> bytes) {
      return append(bytes, retain_prefix);
    });
  }

  template <Allocator Memory>
  int CommandOutput<Memory>::runWithInput(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input) {
    return execute(command, deadline, ExecutionOptions{.input = input}, [&](std::span<const Byte> bytes) {
      return append(bytes, true);
    });
  }

  template <Allocator Memory>
  int CommandOutput<Memory>::runWithInputDiagnostics(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input, BytesConsumer error) {
    const auto retain = [&](std::span<const Byte> bytes) {
      return append(bytes, true);
    };

    return execute(command, deadline, ExecutionOptions{.input = input}, retain, &error);
  }

  template <Allocator Memory>
  int CommandOutput<Memory>::stream(Command<Memory>& command, Clock::time_point deadline, BytesConsumer consume) {
    return execute(command, deadline, ExecutionOptions{}, consume);
  }

  template <Allocator Memory>
  int CommandOutput<Memory>::streamDiagnostics(Command<Memory>& command, Clock::time_point deadline, BytesConsumer output, BytesConsumer error) {
    return execute(command, deadline, ExecutionOptions{}, output, &error);
  }

  template <Allocator Memory>
  int CommandOutput<Memory>::streamWithInput(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input, BytesConsumer output, BytesConsumer error) {
    return execute(command, deadline, ExecutionOptions{.input = input}, output, &error);
  }

  template <Allocator Memory>
  bool CommandOutput<Memory>::truncated() const noexcept {
    return truncated_;
  }

  template <Allocator Memory>
  std::string_view CommandOutput<Memory>::text() const noexcept {
    const auto bytes = output_.readable();

    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the output is text the queue holds as bytes, which char may alias
  }

  template <Allocator Memory>
  bool CommandOutput<Memory>::append(std::span<const Byte> bytes, bool retain_prefix) {
    const auto available = limit_ - output_.size();
    if (bytes.size() > available && retain_prefix) {
      output_.append(bytes.first(available));
      truncated_ = true;
      return false;
    }

    output_.append(bytes);
    return true;
  }

  template <Allocator Memory>
  int CommandOutput<Memory>::execute(Command<Memory>& command, Clock::time_point deadline, ExecutionOptions options, BytesConsumer consume, const BytesConsumer* consume_error) {
    checkCancellation(options.cancelled);
    output_.clear();
    truncated_ = false;
    PipeProcess process{command.specification({})};
    auto input = options.input;
    std::size_t input_offset = 0;

    if (input.empty()) {
      process.closeInput();
    }

    constexpr std::size_t read_bytes = std::size_t{16} * 1024;
    ds::Array<Byte, read_bytes> bytes{};

    while (process.output() >= 0 || process.error() >= 0 || process.input() >= 0) {
      checkCancellation(options.cancelled);
      if (Clock::now() >= deadline) {
        throw RequestError{FailureCode::resource_limit, "Command deadline exceeded"};
      }

      const auto descriptors = pollStreams(process, deadline);
      if (descriptors[2].fd >= 0 && descriptors[2].revents != 0) {
        writeInput(process, input, input_offset);
      }

      if (!readStreams(process, descriptors, bytes.viewMut(), consume, consume_error)) {
        return 0;
      }
    }

    while (Clock::now() < deadline) {
      checkCancellation(options.cancelled);
      if (const auto status = process.reap()) {
        return shellExitCode(*status);
      }

      ::poll(nullptr, 0, 1);
    }

    throw RequestError{FailureCode::resource_limit, "Command deadline exceeded"};
  }

  template <Allocator Memory>
  void CommandOutput<Memory>::writeInput(PipeProcess& process, std::span<const std::string_view>& input, std::size_t& offset) {
    while (!input.empty()) {
      if (offset == input.front().size()) {
        input = input.subspan(1);
        offset = 0;
        continue;
      }

      const auto pending = input.front().substr(offset);
      const auto count = ::write(process.input(), pending.data(), pending.size());
      if (count > 0) {
        offset += static_cast<std::size_t>(count);
      } else if (count < 0 && !socketWouldBlock(sys::lastError())) {
        throw SystemError{"Write command input"};
      } else {
        return;
      }
    }

    process.closeInput();
  }

  template <Allocator Memory>
  void CommandOutput<Memory>::checkCancellation(const std::atomic<bool>* request_cancelled) const {
    if ((cancelled_ != nullptr && *cancelled_) || (request_cancelled != nullptr && *request_cancelled)) {
      throw RequestError{FailureCode::invalid_request, "Command cancelled"};
    }
  }

  ExecutablePath::ExecutablePath() {
    ds::Array<char, PATH_MAX> original{};
#ifdef __APPLE__
    auto size = static_cast<std::uint32_t>(original.size());
    if (::_NSGetExecutablePath(original.dataMut(), &size) != 0) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }

#else
    const auto length = ::readlink("/proc/self/exe", original.dataMut(), original.size());
    if (length < 0) {
      throw SystemError{"Read runtime executable path"};
    }
    if (static_cast<std::size_t>(length) >= original.size()) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }
    original.atMut(length) = '\0';
#endif
    if (::realpath(original.data(), path_.dataMut()) == nullptr) {
      throw SystemError{"Resolve runtime executable"};
    }
  }

  ExecutablePath::ExecutablePath(std::string_view name)
      : ExecutablePath() {
    const std::string_view self = path_.data();
    const auto directory = self.substr(0, self.rfind('/') + 1);
    if (directory.size() + name.size() >= path_.size()) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }

    // The directory views the path written below, so its length is read first.
    const auto start = directory.size();

    std::ranges::copy(name, path_.viewMut().subspan(start).begin());
    path_.atMut(start + name.size()) = '\0';
  }

  ds::Option<ExecutablePath> ExecutablePath::sibling(std::initializer_list<std::string_view> candidates) {
    const ExecutablePath self;
    const std::string_view own = self.path_.data();
    const auto directory = own.substr(0, own.rfind('/') + 1);

    for (const auto candidate : candidates) {
      ds::Array<char, PATH_MAX> path{};
      if (directory.size() + candidate.size() >= path.size()) {
        continue;
      }

      std::ranges::copy(candidate, std::ranges::copy(directory, path.dataMut()).out);
      path.atMut(directory.size() + candidate.size()) = '\0';
      struct stat info{};
      ExecutablePath found{self};
      if (::stat(path.data(), &info) == 0 && S_ISREG(info.st_mode) && ::access(path.data(), X_OK) == 0 && exactlyNamed(path.data()) && ::realpath(path.data(), found.path_.dataMut()) != nullptr) {
        return found;
      }
    }

    return ds::none;
  }

  const char* ExecutablePath::cStr() const noexcept {
    return path_.data();
  }

  std::string_view ExecutablePath::view() const noexcept {
    return path_.data();
  }

  bool ExecutablePath::exactlyNamed(const char* path) noexcept {
#ifdef __APPLE__
    attrlist request{};

    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.commonattr = ATTR_CMN_NAME;
    alignas(attrreference_t) ds::Array<char, sizeof(std::uint32_t) + sizeof(attrreference_t) + (std::size_t{NAME_MAX} * 3) + 1> answer{};
    if (::getattrlist(path, &request, answer.dataMut(), answer.size(), FSOPT_NOFOLLOW) != 0) {
      return false;
    }

    constexpr auto reference_at = sizeof(std::uint32_t);
    ds::Array<char, sizeof(attrreference_t)> reference_bytes{};

    std::ranges::copy(answer.view().subspan<reference_at, sizeof(attrreference_t)>(), reference_bytes.viewMut().begin());
    const auto reference = std::bit_cast<attrreference_t>(reference_bytes);
    const auto offset = static_cast<std::size_t>(reference.attr_dataoffset);
    const auto length = static_cast<std::size_t>(reference.attr_length);
    if (reference.attr_dataoffset < 0 || length == 0 || offset > answer.size() - reference_at || length > answer.size() - reference_at - offset) {
      return false;
    }

    // The length counts the terminating NUL.
    const auto name_bytes = answer.view().subspan(reference_at + offset, length - 1);
    const std::string_view name{name_bytes.data(), name_bytes.size()};
    std::string_view written{path};

    written.remove_prefix(written.rfind('/') + 1);
    return name == written;
#else
    static_cast<void>(path);
    return true;
#endif
  }

  FixedText<PATH_MAX> loginShell() {
    FixedText<PATH_MAX> shell;
    const auto pick = [&](const char* candidate) {
      if (candidate == nullptr || *candidate != '/' || std::string_view{candidate}.size() > PATH_MAX) {
        return false;
      }

      shell.assign(candidate);
      return true;
    };
    if (!pick(std::getenv("SHELL"))) { // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
      constexpr std::size_t account_record_bytes = std::size_t{16} * 1024;
      passwd account{};
      passwd* found = nullptr;
      ds::Array<char, account_record_bytes> storage{};
      const bool known = ::getpwuid_r(::getuid(), &account, storage.dataMut(), storage.size(), &found) == 0 && found != nullptr;

      if (!known || !pick(account.pw_shell)) {
        shell.assign("/bin/sh");
      }
    }

    return shell;
  }

  std::string_view loginShellScript(std::string_view shell) noexcept {
    auto name = shell;

    name.remove_prefix(shell.rfind('/') + 1);
    if (name == "bash" || name == "zsh" || name == "ksh") {
      return R"(exec -- "$0" "$@")";
    }

    if (name == "sh" || name == "dash") {
      return R"(exec "$0" "$@")";
    }

    return name == "fish" ? "exec $argv" : std::string_view{};
  }

  void checkSpawn(int result) {
    if (result != 0) {
      throw SystemError{"Prepare child process", result};
    }
  }

  SpawnOptions::SpawnOptions(short flags) {
    checkSpawn(posix_spawnattr_init(&attributes));

    try {
      checkSpawn(posix_spawn_file_actions_init(&actions));
    } catch (...) {
      posix_spawnattr_destroy(&attributes);
      throw;
    }

    sigset_t empty{};

    sigemptyset(&empty);
    sigset_t defaults{};

    sigfillset(&defaults);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setpgroup(&attributes, 0);
#ifdef __APPLE__
    flags = static_cast<short>(combineFlags(static_cast<int>(flags), POSIX_SPAWN_CLOEXEC_DEFAULT));
#endif
    checkSpawn(posix_spawnattr_setflags(&attributes, static_cast<short>(combineFlags(static_cast<int>(flags), POSIX_SPAWN_SETSIGDEF, POSIX_SPAWN_SETSIGMASK))));
  }

  SpawnOptions::~SpawnOptions() {
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
  }

  void SpawnOptions::redirect(int source, int destination) {
    checkSpawn(posix_spawn_file_actions_adddup2(&actions, source, destination));
  }

  void SpawnOptions::changeDirectory(const char* path) {
#ifdef __APPLE__
    checkSpawn(::posix_spawn_file_actions_addchdir(&actions, path));
#else
    checkSpawn(::posix_spawn_file_actions_addchdir_np(&actions, path));
#endif
  }

  void SpawnOptions::closeOthers() {
#ifdef __linux__
    if (const int added = sys::addSpawnCloseFrom(&actions, STDERR_FILENO + 1); added != ENOSYS) {
      checkSpawn(added);
      return;
    }

    DIR* descriptors = ::opendir("/proc/self/fd");
    if (descriptors == nullptr) {
      throw SystemError{"List open descriptors"};
    }

    const int own = ::dirfd(descriptors);
    while (const auto* entry = ::readdir(descriptors)) {
      char* end = nullptr;
      const auto descriptor = std::strtol(entry->d_name, &end, 10);
      if (*end == '\0' && end != entry->d_name && descriptor > STDERR_FILENO && descriptor != own) {
        const int flags = ::fcntl(static_cast<int>(descriptor), F_GETFD);
        if (flags >= 0) {
          ::fcntl(static_cast<int>(descriptor), F_SETFD, flags | FD_CLOEXEC);
        }
      }
    }

    ::closedir(descriptors);
#endif
  }

  void SpawnOptions::keepStandardStreams() {
    // A dup2 onto itself keeps the stream open across exec where
    // POSIX_SPAWN_CLOEXEC_DEFAULT would close it, and leaves an earlier redirect in place.
    for (const int stream : {STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO}) {
      redirect(stream, stream);
    }

    closeOthers();
  }

  template class Command<Memory>;
  template class Command<ConcurrentMemory>;
  template class Command<SystemAllocator>;
  template class Command<BudgetAllocator<SystemAllocator>>;
  template class Command<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  template class CommandOutput<Memory>;
  template class CommandOutput<ConcurrentMemory>;
  template class CommandOutput<SystemAllocator>;
  template class CommandOutput<BudgetAllocator<SystemAllocator>>;
  template class CommandOutput<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
