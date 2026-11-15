module telar.platform.process;

import std;
import telar.sys.posix;
import telar.tbc;
import telar.sys.process;
import telar.platform.error;
#if defined(__APPLE__)
import telar.sys.apple;
#endif
#if defined(__linux__)
import telar.sys.linux_api;
#endif

namespace telar::runtime {

  bool findExecutable(std::string_view path, std::string_view program, std::span<char, PATH_MAX> found, std::string_view cwd) noexcept {
    for (;;) {
      const auto separator = path.find(':');
      const auto directory = path.substr(0, separator);
      const bool relative = directory.empty() || directory.front() != '/';
      const std::string_view base = !relative ? std::string_view{} : cwd.empty() ? std::string_view{"."}
                                                                                 : cwd;
      const auto length = base.size() + (relative ? 1 : 0) + directory.size() + 1 + program.size();
      if (length < found.size()) {
        auto* cursor = std::ranges::copy(base, found.data()).out;

        if (relative) {
          *cursor++ = '/';
        }

        cursor = std::ranges::copy(directory, cursor).out;
        *cursor++ = '/';
        cursor = std::ranges::copy(program, cursor).out;
        *cursor = '\0';
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
  Command<Memory>::Command(tbc::view<Memory&, tbc::lt::a> memory, const Launch& launch, CommandPurpose purpose)
      : executable_(AllocatorRef<char, Memory>{memory}),
        cwd_(launch.cwd, AllocatorRef<char, Memory>{memory}),
        arguments_(AllocatorRef<String<Memory>, Memory>{memory}),
        spawn_arguments_(AllocatorRef<String<Memory>, Memory>{memory}),
        environment_memory_(memory),
        environment_(AllocatorRef<String<SensitiveMemory>, SensitiveMemory>{environment_memory_}),
        argument_pointers_(AllocatorRef<char*, Memory>{memory}),
        environment_pointers_(AllocatorRef<char*, Memory>{memory}),
        memory_(memory),
        restorable_(launch.environment_mode == EnvironmentMode::inherit_runtime) {
    if (cwd_.empty()) {
      std::array<char, PATH_MAX> current{};
      if (::getcwd(current.data(), current.size()) == nullptr) {
        throw SystemError{"resolve working directory"};
      }

      cwd_.assign(current.data());
    }

    for (const auto argument : launch.arguments) {
      arguments_.emplace_back(argument, AllocatorRef<char, Memory>{memory});
    }

    if (arguments_.empty()) {
      arguments_.emplace_back(loginShell().view(), AllocatorRef<char, Memory>{memory});
    }

    if (launch.environment_mode == EnvironmentMode::inherit_runtime) {
      for (char** entry = environ; *entry != nullptr; ++entry) {
        environment_.emplace_back(*entry, AllocatorRef<char, SensitiveMemory>{environment_memory_});
      }
    }

    for (const auto& entry : launch.environment) {
      setEnvironment(entry.name, entry.value);
    }

    std::erase_if(environment_, [purpose](const auto& entry) {
      if (purpose == CommandPurpose::configured_helper) {
        return false;
      }

      const auto name = std::string_view{entry}.substr(0, entry.find('='));

      if (purpose == CommandPurpose::administration) {
        return name == "TELAR_PANE_ID" || name == "TELAR_PANE_GENERATION" || name == "TELAR_WORKSPACE_ID" || name == "TELAR_TAB_ID" || name == "SSH_AUTH_SOCK";
      }

      return name == "GHOSTTY_RESOURCES_DIR" || name == "TELAR_SOCKET" || name == "TERM_PROGRAM_VERSION";
    });

    if (purpose == CommandPurpose::terminal) {
      setEnvironment("TERM_PROGRAM", control::program_name);
      setEnvironment("TERM_PROGRAM_VERSION", control::program_version);
      setEnvironment("TELAR_TERM_PROGRAM", "telar");
      setEnvironment("TERM", "xterm-256color");
      setEnvironment("COLORTERM", "truecolor");
    }

    resolveExecutable();
  }

  template <Allocator Memory>
  void Command<Memory>::removeEnvironmentPrefix(std::string_view prefix) {
    std::erase_if(environment_, [prefix](const auto& entry) {
      return entry.starts_with(prefix);
    });
  }

  template <Allocator Memory>
  std::optional<std::string_view> Command<Memory>::environment(std::string_view name) const noexcept {
    for (const auto& entry : environment_) {
      if (definesVariable(entry, name)) {
        return std::string_view{entry}.substr(name.size() + 1);
      }
    }

    return std::nullopt;
  }

  template <Allocator Memory>
  void Command<Memory>::removeEnvironment(std::string_view name) {
    std::erase_if(environment_, [name](auto& entry) {
      if (!definesVariable(entry, name)) {
        return false;
      }

      eraseSensitive(entry.data(), entry.size());
      return true;
    });
  }

  template <Allocator Memory>
  void Command<Memory>::replaceSpawnArguments(std::span<const std::string_view> arguments) {
    spawn_arguments_.clear();
    for (const auto argument : arguments) {
      spawn_arguments_.emplace_back(argument, AllocatorRef<char, Memory>{memory_});
    }
  }

  template <Allocator Memory>
  void Command<Memory>::setEnvironment(std::string_view name, std::string_view value) {
    String<SensitiveMemory> entry{name, AllocatorRef<char, SensitiveMemory>{environment_memory_}};

    entry.push_back('=');
    entry.append(value);

    for (auto& existing : environment_) {
      const auto separator = existing.find('=');
      if (std::string_view{existing}.substr(0, separator) == name) {
        eraseSensitive(existing.data(), existing.size());
        existing = std::move(entry);
        return;
      }
    }

    environment_.push_back(std::move(entry));
  }

  template <Allocator Memory>
  SpawnSpec Command<Memory>::specification(TerminalSize size) {
    argument_pointers_.clear();
    environment_pointers_.clear();

    argument_pointers_.push_back(arguments_.front().data());
    const auto rest = spawn_arguments_.empty() ? std::span<String<Memory>>{arguments_}.subspan(1) : std::span<String<Memory>>{spawn_arguments_};

    for (auto& argument : rest) {
      argument_pointers_.push_back(argument.data());
    }

    for (auto& entry : environment_) {
      environment_pointers_.push_back(entry.data());
    }

    argument_pointers_.push_back(nullptr);
    environment_pointers_.push_back(nullptr);
    return SpawnSpec{
        .executable = executable_.c_str(),
        .cwd = cwd_.c_str(),
        .arguments = argument_pointers_.data(),
        .environment = environment_pointers_.data(),
        .size = size,
    };
  }

  template <Allocator Memory>
  std::string_view Command<Memory>::cwd() const noexcept {
    return cwd_;
  }

  template <Allocator Memory>
  std::span<const String<Memory>> Command<Memory>::arguments() const noexcept {
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
    if (program.find('/') != String<Memory>::npos) {
      executable_ = program;
      return;
    }

    std::string_view path = "/usr/bin:/bin";

    for (const auto& entry : environment_) {
      if (std::string_view{entry}.starts_with("PATH=")) {
        path = std::string_view{entry}.substr(5);
        break;
      }
    }

    std::array<char, PATH_MAX> found;
    if (!findExecutable(path, program, found, cwd())) {
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

    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
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

    std::array<Byte, 16 * 1024> bytes;

    while (process.output() >= 0 || process.error() >= 0 || process.input() >= 0) {
      checkCancellation(options.cancelled);
      if (Clock::now() >= deadline) {
        throw RequestError{FailureCode::resource_limit, "Command deadline exceeded"};
      }

      std::array<pollfd, 3> descriptors{{{process.output(), POLLIN, 0}, {process.error(), POLLIN, 0}, {process.input(), POLLOUT, 0}}};
      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
      const int result = ::poll(descriptors.data(), descriptors.size(), static_cast<int>(std::clamp<std::int64_t>(remaining, 0, 20)));
      if (result < 0 && sys::lastError() != EINTR) {
        throw SystemError{"Wait for command output"};
      }

      if (descriptors[2].fd >= 0 && descriptors[2].revents != 0) {
        writeInput(process, input, input_offset);
      }

      for (std::size_t index = 0; index < 2; ++index) {
        if (descriptors[index].fd < 0 || descriptors[index].revents == 0) {
          continue;
        }

        const auto count = ::read(descriptors[index].fd, bytes.data(), bytes.size());
        if (count > 0) {
          if (index == 0 && !consume(std::span<const Byte>{bytes}.first(static_cast<std::size_t>(count)))) {
            return 0;
          }

          if (index == 1 && consume_error != nullptr) {
            (*consume_error)(std::span<const Byte>{bytes}.first(static_cast<std::size_t>(count)));
          }
        } else if (count == 0) {
          if (index == 0) {
            process.closeOutput();
          } else {
            process.closeError();
          }
        } else if (sys::lastError() != EAGAIN && sys::lastError() != EWOULDBLOCK && sys::lastError() != EINTR) {
          throw SystemError{"Read command output"};
        }
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

      const auto count = ::write(process.input(), input.front().data() + offset, input.front().size() - offset);
      if (count > 0) {
        offset += static_cast<std::size_t>(count);
      } else if (count < 0 && sys::lastError() != EAGAIN && sys::lastError() != EWOULDBLOCK && sys::lastError() != EINTR) {
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
    std::array<char, PATH_MAX> original;
#if defined(__APPLE__)
    auto size = static_cast<std::uint32_t>(original.size());
    if (::_NSGetExecutablePath(original.data(), &size) != 0) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }

#else
    const auto length = ::readlink("/proc/self/exe", original.data(), original.size());
    if (length < 0) {
      throw SystemError{"Read runtime executable path"};
    }
    if (static_cast<std::size_t>(length) >= original.size()) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }
    original[length] = '\0';
#endif
    if (::realpath(original.data(), path_.data()) == nullptr) {
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

    name.copy(path_.data() + directory.size(), name.size());
    path_[directory.size() + name.size()] = '\0';
  }

  std::optional<ExecutablePath> ExecutablePath::sibling(std::initializer_list<std::string_view> candidates) {
    ExecutablePath self;
    const std::string_view own = self.path_.data();
    const auto directory = own.substr(0, own.rfind('/') + 1);

    for (const auto candidate : candidates) {
      std::array<char, PATH_MAX> path;
      if (directory.size() + candidate.size() >= path.size()) {
        continue;
      }

      std::ranges::copy(candidate, std::ranges::copy(directory, path.data()).out);
      path[directory.size() + candidate.size()] = '\0';
      struct stat info{};
      ExecutablePath found{self};
      if (::stat(path.data(), &info) == 0 && S_ISREG(info.st_mode) && ::access(path.data(), X_OK) == 0 && exactlyNamed(path.data()) && ::realpath(path.data(), found.path_.data()) != nullptr) {
        return found;
      }
    }

    return std::nullopt;
  }

  const char* ExecutablePath::c_str() const noexcept {
    return path_.data();
  }

  std::string_view ExecutablePath::view() const noexcept {
    return path_.data();
  }

  bool ExecutablePath::exactlyNamed(const char* path) noexcept {
#if defined(__APPLE__)
    attrlist request{};

    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.commonattr = ATTR_CMN_NAME;
    alignas(attrreference_t) std::array<char, sizeof(std::uint32_t) + sizeof(attrreference_t) + NAME_MAX * 3 + 1> answer{};
    if (::getattrlist(path, &request, answer.data(), answer.size(), FSOPT_NOFOLLOW) != 0) {
      return false;
    }

    constexpr auto reference_at = sizeof(std::uint32_t);
    attrreference_t reference{};

    std::memcpy(&reference, answer.data() + reference_at, sizeof(reference));
    const auto offset = static_cast<std::size_t>(reference.attr_dataoffset);
    const auto length = static_cast<std::size_t>(reference.attr_length);
    if (reference.attr_dataoffset < 0 || length == 0 || offset > answer.size() - reference_at || length > answer.size() - reference_at - offset) {
      return false;
    }

    // The length counts the terminating NUL.
    const std::string_view name{answer.data() + reference_at + offset, length - 1};
    const std::string_view written{path};

    return name == written.substr(written.rfind('/') + 1);
#else
    static_cast<void>(path);
    return true;
#endif
  }

  FixedText<PATH_MAX> loginShell() {
    FixedText<PATH_MAX> shell;
    const auto pick = [&](const char* candidate) {
      if (candidate == nullptr || *candidate != '/' || std::strlen(candidate) > PATH_MAX) {
        return false;
      }

      shell.assign(candidate);
      return true;
    };
    if (!pick(std::getenv("SHELL"))) {
      const auto* entry = ::getpwuid(::getuid());
      if (entry == nullptr || !pick(entry->pw_shell)) {
        shell.assign("/bin/sh");
      }
    }

    return shell;
  }

  std::string_view loginShellScript(std::string_view shell) noexcept {
    const auto name = shell.substr(shell.rfind('/') + 1);
    if (name == "bash" || name == "zsh" || name == "ksh") {
      return "exec -- \"$0\" \"$@\"";
    }

    if (name == "sh" || name == "dash") {
      return "exec \"$0\" \"$@\"";
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

    sigset_t empty;

    sigemptyset(&empty);
    sigset_t defaults;

    sigfillset(&defaults);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setpgroup(&attributes, 0);
#if defined(__APPLE__)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    checkSpawn(posix_spawnattr_setflags(&attributes, flags | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK));
  }

  SpawnOptions::~SpawnOptions() {
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
  }

  void SpawnOptions::redirect(int source, int destination) {
    checkSpawn(posix_spawn_file_actions_adddup2(&actions, source, destination));
  }

  void SpawnOptions::changeDirectory(const char* path) {
#if defined(__APPLE__)
    checkSpawn(::posix_spawn_file_actions_addchdir(&actions, path));
#else
    checkSpawn(::posix_spawn_file_actions_addchdir_np(&actions, path));
#endif
  }

  void SpawnOptions::closeOthers() {
#if defined(__linux__)
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
