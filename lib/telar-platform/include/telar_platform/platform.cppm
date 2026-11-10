module;
#include "tbc/view.hpp"
#include <new>
#include <stdlib.h>
#include <sys/mman.h>

#if (defined(__APPLE__))
#include <libproc.h>
#endif
#if (!(defined(__APPLE__)))
#include <limits.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/close_range.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/syscall.h>
#endif
#include <unistd.h>

#include <cerrno>

#include <sys/types.h>

#include "telar_platform/process_environment.h"

#include <cstddef>
#include <cstring>
#include <limits.h>

#include <cassert>
#include <cstdint>
#include <poll.h>
#include <sys/wait.h>

#include <cstdlib>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif

#include <fcntl.h>
#include <sys/stat.h>



#include <sys/un.h>

#include <csignal>
#include <dirent.h>
#include <spawn.h>

#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif

#include <cstdio>

#include <sys/socket.h>

#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif

#include <openssl/sha.h>

#include <pthread.h>

#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif

export module telar.platform;

import std;

export import telar.base.memory;


import telar.client.protocol;
export import telar.base.text;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: telar_platform/child_descriptors.cppm
export {
#if defined(__APPLE__)
#else
#endif

namespace telar::runtime {

inline void closeChildDescriptors(int retained, int descriptor_limit) noexcept {
#if defined(__APPLE__)
  // Only the forked child enumerates descriptors, so no other thread can open
  // one during the scan. proc_pidinfo copies kernel data into this stack buffer.
  std::array<proc_fdinfo, 1024> descriptors;
  const int bytes = ::proc_pidinfo(::getpid(), PROC_PIDLISTFDS, 0, descriptors.data(), sizeof(descriptors));

  if (bytes > 0 && bytes < static_cast<int>(sizeof(descriptors)) && bytes % sizeof(proc_fdinfo) == 0) {
    const auto count = static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo);
    for (std::size_t index = 0; index < count; ++index) {
      const int descriptor = descriptors[index].proc_fd;
      if (descriptor > STDERR_FILENO && descriptor != retained) {
        ::close(descriptor);
      }
    }
    return;
  }
#else
  const auto first = static_cast<unsigned>(STDERR_FILENO + 1);
  const bool lower_closed = retained <= static_cast<int>(first) || ::syscall(SYS_close_range, first, static_cast<unsigned>(retained - 1), 0) == 0;
  const bool upper_closed = ::syscall(SYS_close_range, static_cast<unsigned>(retained + 1), UINT_MAX, 0) == 0;
  if (lower_closed && upper_closed) {
    return;
  }
#endif

  for (int descriptor = STDERR_FILENO + 1; descriptor < descriptor_limit; ++descriptor) {
    if (descriptor != retained) {
      ::close(descriptor);
    }
  }
}

}
}

// Interface: telar_platform/error.cppm
export {
namespace telar::runtime {

class SystemError final : public std::exception {
public:
  inline explicit SystemError(const char *operation, int code = errno) noexcept
      : operation_(operation),
        code_(code) {}

  inline const char *what() const noexcept override {
    return operation_;
  }

  inline int code() const noexcept {
    return code_;
  }

private:
  const char *operation_;
  int code_;
};

}
}

// Interface: telar_platform/pty_process.cppm
export {
namespace telar::runtime {

struct SpawnSpec {
  const char *executable;
  const char *cwd;
  char *const *arguments;
  char *const *environment;
  TerminalSize size;
};

class PtyProcess {
public:
  explicit PtyProcess(const SpawnSpec &specification);
  ~PtyProcess();
  PtyProcess(const PtyProcess &) = delete;
  PtyProcess &operator=(const PtyProcess &) = delete;

  inline int descriptor() const noexcept {
    return master_.get();
  }

  inline pid_t processId() const noexcept {
    return process_id_;
  }

  void resize(TerminalSize size);
  std::optional<pid_t> foregroundProcessGroup() const noexcept;
  void signal(int signal_number) const noexcept;
  void shutdown() const noexcept;
  std::optional<int> reap() noexcept;

private:
  FileDescriptor master_;
  pid_t process_id_ = -1;
  std::optional<int> exit_status_;
};

}
}

// Interface: telar_platform/command.cppm
export {

namespace telar::runtime {

enum class CommandPurpose {
  terminal,
  administration,
  configured_helper
};

template <Allocator Memory>
class Command {
public:
  // Copies the launch; it keeps only its allocator, region `a`.
  inline explicit Command(tbc::view<Memory &, tbc::lt::a> memory, const Launch &launch, CommandPurpose purpose = CommandPurpose::terminal)
      : executable_(AllocatorRef<char, Memory>{memory}),
        cwd_(launch.cwd, AllocatorRef<char, Memory>{memory}),
        arguments_(AllocatorRef<String<Memory>, Memory>{memory}),
        spawn_arguments_(AllocatorRef<String<Memory>, Memory>{memory}),
        environment_memory_(memory),
        environment_(AllocatorRef<String<SensitiveMemory>, SensitiveMemory>{environment_memory_}),
        argument_pointers_(AllocatorRef<char *, Memory>{memory}),
        environment_pointers_(AllocatorRef<char *, Memory>{memory}),
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
      const char *shell = std::getenv("SHELL");
      arguments_.emplace_back(shell != nullptr ? shell : "/bin/sh", AllocatorRef<char, Memory>{memory});
    }

    if (launch.environment_mode == EnvironmentMode::inherit_runtime) {
      for (char **entry = environ; *entry != nullptr; ++entry) {
        environment_.emplace_back(*entry, AllocatorRef<char, SensitiveMemory>{environment_memory_});
      }
    }

    for (const auto &entry : launch.environment) {
      setEnvironment(entry.name, entry.value);
    }

    std::erase_if(environment_, [purpose](const auto &entry) {
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

  Command(const Command &) = delete;
  Command &operator=(const Command &) = delete;

  inline void removeEnvironmentPrefix(std::string_view prefix) {
    std::erase_if(environment_, [prefix](const auto &entry) { return entry.starts_with(prefix); });
  }

  inline std::optional<std::string_view> environment(std::string_view name) const noexcept {
    for (const auto &entry : environment_) {
      if (definesVariable(entry, name)) {
        return std::string_view{entry}.substr(name.size() + 1);
      }
    }
    return std::nullopt;
  }

  inline void removeEnvironment(std::string_view name) {
    std::erase_if(environment_, [name](auto &entry) {
      if (!definesVariable(entry, name)) {
        return false;
      }

      eraseSensitive(entry.data(), entry.size());
      return true;
    });
  }

  // The process starts with these after the program instead of the launch's own arguments,
  // which stay what the pane records and restores.
  inline void replaceSpawnArguments(std::span<const std::string_view> arguments) {
    spawn_arguments_.clear();
    for (const auto argument : arguments) {
      spawn_arguments_.emplace_back(argument, AllocatorRef<char, Memory>{memory_});
    }
  }

  inline void setEnvironment(std::string_view name, std::string_view value) {
    String<SensitiveMemory> entry{name, AllocatorRef<char, SensitiveMemory>{environment_memory_}};
    entry.push_back('=');
    entry.append(value);

    for (auto &existing : environment_) {
      const auto separator = existing.find('=');
      if (std::string_view{existing}.substr(0, separator) == name) {
        eraseSensitive(existing.data(), existing.size());
        existing = std::move(entry);
        return;
      }
    }

    environment_.push_back(std::move(entry));
  }

  inline SpawnSpec specification(TerminalSize size) {
    argument_pointers_.clear();
    environment_pointers_.clear();

    argument_pointers_.push_back(arguments_.front().data());
    const auto rest = spawn_arguments_.empty() ? std::span<String<Memory>>{arguments_}.subspan(1) : std::span<String<Memory>>{spawn_arguments_};
    for (auto &argument : rest) {
      argument_pointers_.push_back(argument.data());
    }

    for (auto &entry : environment_) {
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

  inline std::string_view cwd() const noexcept {
    return cwd_;
  }

  inline std::span<const String<Memory>> arguments() const noexcept {
    return arguments_;
  }

  inline bool restorable() const noexcept {
    return restorable_;
  }

private:
  inline static bool definesVariable(std::string_view entry, std::string_view name) noexcept {
    return entry.size() > name.size() && entry[name.size()] == '=' && entry.starts_with(name);
  }

  inline void resolveExecutable() {
    const auto &program = arguments_.front();
    if (program.find('/') != String<Memory>::npos) {
      executable_ = program;
      return;
    }

    std::string_view path = "/usr/bin:/bin";
    for (const auto &entry : environment_) {
      if (std::string_view{entry}.starts_with("PATH=")) {
        path = std::string_view{entry}.substr(5);
        break;
      }
    }

    while (true) {
      const auto separator = path.find(':');
      const auto directory = path.substr(0, separator);
      executable_.clear();
      if (directory.empty() || directory.front() != '/') {
        executable_.append(cwd());
        executable_.push_back('/');
      }
      executable_.append(directory);
      executable_.push_back('/');
      executable_.append(program);

      if (::access(executable_.c_str(), X_OK) == 0) {
        return;
      }

      if (separator == std::string_view::npos) {
        throw SystemError{"resolve pane executable", ENOENT};
      }

      path.remove_prefix(separator + 1);
    }
  }

  using SensitiveMemory = ErasingAllocator<Memory>;
  tbc::view<String<Memory>, tbc::lt::a> executable_;
  tbc::view<String<Memory>, tbc::lt::a> cwd_;
  tbc::view<Vector<String<Memory>, Memory>, tbc::lt::a> arguments_;
  tbc::view<Vector<String<Memory>, Memory>, tbc::lt::a> spawn_arguments_;
  tbc::view<SensitiveMemory, tbc::lt::a> environment_memory_;
  // The environment allocates from the sibling allocator, and the spawn arrays point into the
  // command's own strings, so a command keeps its address.
  tbc::view<Vector<String<SensitiveMemory>, SensitiveMemory>, tbc::lt::self> environment_;
  tbc::view<Vector<char *, Memory>, tbc::lt::self> argument_pointers_;
  tbc::view<Vector<char *, Memory>, tbc::lt::self> environment_pointers_;
  tbc::view<Memory &, tbc::lt::a> memory_;
  bool restorable_;
};

template <Allocator Memory>
Command(Memory &memory, const Launch &launch, CommandPurpose purpose = CommandPurpose::terminal) -> Command<Memory>;

}
}

// Interface: telar_platform/pipe_process.cppm
export {
namespace telar::runtime {

enum class ProcessInput { pipe,
                          buffered_socket };

class PipeProcess {
public:
  explicit PipeProcess(const SpawnSpec &specification, ProcessInput input = ProcessInput::pipe);
  ~PipeProcess();
  PipeProcess(const PipeProcess &) = delete;
  PipeProcess &operator=(const PipeProcess &) = delete;

  inline int input() const noexcept {
    return input_.get();
  }

  inline int output() const noexcept {
    return output_.get();
  }

  inline int error() const noexcept {
    return error_.get();
  }

  inline pid_t processId() const noexcept {
    return process_id_;
  }

  inline void closeInput() noexcept {
    input_.reset();
  }

  inline void closeOutput() noexcept {
    output_.reset();
  }

  inline void closeError() noexcept {
    error_.reset();
  }

  void signal(int number) const noexcept;
  std::optional<int> reap() noexcept;

private:
  FileDescriptor input_;
  FileDescriptor output_;
  FileDescriptor error_;
  pid_t process_id_ = -1;
  std::optional<int> exit_status_;
};

}
}

// Interface: telar_platform/command_output.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CommandOutput {
public:
  using Clock = std::chrono::steady_clock;

  inline explicit CommandOutput(Memory &memory, std::size_t limit, const std::atomic<bool> *cancelled = nullptr)
      : output_(memory, limit),
        limit_(limit),
        cancelled_(cancelled) {}

  inline int run(Command<Memory> &command, Clock::time_point deadline, bool retain_prefix = false, const std::atomic<bool> *cancelled = nullptr) {
    return execute(command, deadline, ExecutionOptions{.cancelled = cancelled}, [&](std::span<const Byte> bytes) { return append(bytes, retain_prefix); });
  }

  inline int runWithInput(Command<Memory> &command, Clock::time_point deadline, std::span<const std::string_view> input) {
    return execute(command, deadline, ExecutionOptions{.input = input}, [&](std::span<const Byte> bytes) { return append(bytes, true); });
  }

  template <typename ErrorConsumer>
  inline int runWithInputDiagnostics(Command<Memory> &command, Clock::time_point deadline, std::span<const std::string_view> input, ErrorConsumer &&error) {
    return execute(command, deadline, ExecutionOptions{.input = input}, [&](std::span<const Byte> bytes) { return append(bytes, true); }, error);
  }

  template <typename Consumer>
  inline int stream(Command<Memory> &command, Clock::time_point deadline, Consumer &&consume) {
    return execute(command, deadline, ExecutionOptions{}, consume);
  }

  template <typename OutputConsumer, typename ErrorConsumer>
  inline int streamDiagnostics(Command<Memory> &command, Clock::time_point deadline, OutputConsumer &&output, ErrorConsumer &&error) {
    return execute(command, deadline, ExecutionOptions{}, output, error);
  }

  inline bool truncated() const noexcept {
    return truncated_;
  }

  inline std::string_view text() const noexcept {
    const auto bytes = output_.readable();
    return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
  }

private:
  struct ExecutionOptions {
    std::span<const std::string_view> input{};
    const std::atomic<bool> *cancelled = nullptr;
  };

  inline bool append(std::span<const Byte> bytes, bool retain_prefix) {
    const auto available = limit_ - output_.size();
    if (bytes.size() > available && retain_prefix) {
      output_.append(bytes.first(available));
      truncated_ = true;
      return false;
    }

    output_.append(bytes);
    return true;
  }

  template <typename Consumer, typename ErrorConsumer = std::nullptr_t>
  inline int execute(Command<Memory> &command, Clock::time_point deadline, ExecutionOptions options, Consumer &&consume, ErrorConsumer &&consume_error = nullptr) {
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
      if (result < 0 && errno != EINTR) {
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
          if constexpr (!std::is_same_v<std::remove_cvref_t<ErrorConsumer>, std::nullptr_t>) {
            if (index == 1) {
              consume_error(std::span<const Byte>{bytes}.first(static_cast<std::size_t>(count)));
            }
          }
        } else if (count == 0) {
          if (index == 0) {
            process.closeOutput();
          } else {
            process.closeError();
          }
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
          throw SystemError{"Read command output"};
        }
      }
    }

    while (Clock::now() < deadline) {
      checkCancellation(options.cancelled);
      if (const auto status = process.reap()) {
        return WIFEXITED(*status) ? WEXITSTATUS(*status) : 128 + WTERMSIG(*status);
      }
      ::poll(nullptr, 0, 1);
    }

    throw RequestError{FailureCode::resource_limit, "Command deadline exceeded"};
  }

  inline static void writeInput(PipeProcess &process, std::span<const std::string_view> &input, std::size_t &offset) {
    while (!input.empty()) {
      if (offset == input.front().size()) {
        input = input.subspan(1);
        offset = 0;
        continue;
      }

      const auto count = ::write(process.input(), input.front().data() + offset, input.front().size() - offset);
      if (count > 0) {
        offset += static_cast<std::size_t>(count);
      } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        throw SystemError{"Write command input"};
      } else {
        return;
      }
    }

    process.closeInput();
  }

  inline void checkCancellation(const std::atomic<bool> *request_cancelled) const {
    if ((cancelled_ != nullptr && *cancelled_) || (request_cancelled != nullptr && *request_cancelled)) {
      throw RequestError{FailureCode::invalid_request, "Command cancelled"};
    }
  }

  ByteQueue<Memory> output_;
  std::size_t limit_;
  const std::atomic<bool> *cancelled_;
  bool truncated_ = false;
};

}
}

// Interface: telar_platform/executable_path.cppm
export {
#if defined(__APPLE__)
#else
#endif

namespace telar::runtime {

class ExecutablePath {
public:
  inline ExecutablePath() {
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

  // The executable called `name` beside this one, as installed telar programs are:
  // `telar` and `telar-runtime` share a directory, and symlinks resolve to it first.
  inline explicit ExecutablePath(std::string_view name)
      : ExecutablePath() {
    const std::string_view self = path_.data();
    const auto directory = self.substr(0, self.rfind('/') + 1);
    if (directory.size() + name.size() >= path_.size()) {
      throw SystemError{"Executable path exceeds its limit", ENAMETOOLONG};
    }

    name.copy(path_.data() + directory.size(), name.size());
    path_[directory.size() + name.size()] = '\0';
  }

  inline const char *c_str() const noexcept {
    return path_.data();
  }

  inline std::string_view view() const noexcept {
    return path_.data();
  }

private:
  std::array<char, PATH_MAX> path_;
};

}
}

// Interface: telar_platform/private_directory.cppm
export {
namespace telar::runtime {

inline void createPrivateDirectory(std::string_view path) {
  if (path.empty() || path.front() != '/' || path.size() >= PATH_MAX || path.find('\0') != std::string_view::npos) {
    throw SystemError{"Invalid absolute private directory", EINVAL};
  }

  std::array<char, PATH_MAX> name{};
  std::copy(path.begin(), path.end(), name.begin());
  for (std::size_t index = 1; index <= path.size(); ++index) {
    if (index != path.size() && name[index] != '/') {
      continue;
    }

    const auto separator = name[index];
    name[index] = '\0';
    if (::mkdir(name.data(), 0700) != 0 && errno != EEXIST) {
      throw SystemError{"Create private directory"};
    }
    name[index] = separator;
  }

  FileDescriptor directory{::open(name.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
  struct stat state{};
  if (!directory || ::fstat(directory.get(), &state) != 0) {
    throw SystemError{"Open private directory"};
  }
  if (state.st_uid != ::geteuid()) {
    throw SystemError{"Private directory belongs to another user", EACCES};
  }
  if (::fchmod(directory.get(), 0700) != 0) {
    throw SystemError{"Restrict private directory permissions"};
  }
}

inline FileDescriptor openPrivateParent(std::string_view file_path) {
  const auto separator = file_path.rfind('/');
  if (file_path.empty() || file_path.front() != '/' || file_path.size() >= PATH_MAX || separator == file_path.size() - 1 || file_path.find('\0') != std::string_view::npos) {
    throw SystemError{"invalid absolute runtime file path", EINVAL};
  }

  std::array<char, PATH_MAX> directory{};
  std::copy_n(file_path.data(), std::max<std::size_t>(separator, 1), directory.data());
  FileDescriptor parent{::open(directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
  struct stat state{};
  if (!parent || ::fstat(parent.get(), &state) != 0) {
    throw SystemError{"open runtime file directory"};
  }

  if (state.st_uid != ::geteuid() || (state.st_mode & 0022) != 0) {
    throw SystemError{"runtime directory must be owned by the user and not writable by others", EACCES};
  }

  return parent;
}

}
}

// Interface: telar_platform/process_environment.cppm
export {
namespace telar::runtime {

struct ProcessEnvironment {
  inline std::string_view lookup(const char *name) const noexcept {
    const auto *value = std::getenv(name);
    return value == nullptr ? std::string_view{} : std::string_view{value};
  }
};

// The process's environment, which is one per process: a value looked up in it borrows this object,
// which outlives every caller.
inline constexpr ProcessEnvironment process_environment{};

template <typename Environment>
concept EnvironmentLookup = requires(const Environment &environment, const char *name) {
  { environment.lookup(name) } -> std::same_as<std::string_view>;
};

}
}

// Interface: telar_platform/server_options.cppm
export {
namespace telar::runtime::cli {

enum class ServerAction {
  run,
  stop,
  endpoint,
  bridge,
  help
};
enum class ServerMode {
  foreground,
  background,
  daemonized
};

struct ServerOptions {
  ServerAction action = ServerAction::run;
  ServerMode mode = ServerMode::foreground;
  std::string_view socket;
  std::string_view history;
  std::string_view session;
  std::string_view trace;
  std::string_view config;
  std::string_view profile;
  std::array<std::string_view, 64> engine_arguments;
  std::size_t engine_argument_count = 0;
  bool fresh = false;
  bool no_config = false;
  bool persist_session = true;
  bool resume_agents = true;

  inline static ServerOptions parse(std::span<char *const> arguments) {
    ServerOptions options;
    bool action_selected = false;
    if (!arguments.empty() && std::string_view{arguments.front()} == "server") {
      arguments = arguments.subspan(1);
    }

    for (std::size_t index = 0; index < arguments.size(); ++index) {
      const std::string_view argument = arguments[index];
      const auto value = [&]() -> std::string_view {
        if (++index == arguments.size()) {
          throw std::invalid_argument{"Missing server option value"};
        }

        return arguments[index];
      };
      if (argument == "stop" || argument == "endpoint" || argument == "bridge") {
        if (action_selected) {
          throw std::invalid_argument{"Duplicate server action"};
        }

        action_selected = true;
        options.action = argument == "stop" ? ServerAction::stop : argument == "endpoint" ? ServerAction::endpoint
                                                                                          : ServerAction::bridge;
      } else if (argument == "--help") {
        options.action = ServerAction::help;
      } else if (argument == "--socket") {
        setOnce(options.socket, value());
      } else if (argument == "--history") {
        setOnce(options.history, value());
      } else if (argument == "--session") {
        setOnce(options.session, value());
      } else if (argument == "--trace") {
        setOnce(options.trace, value());
      } else if (argument == "--config") {
        if (options.no_config) {
          throw std::invalid_argument{"Conflicting configuration options"};
        }
        setOnce(options.config, value());
      } else if (argument == "--profile") {
        setOnce(options.profile, value());
      } else if (argument == "--engine-arg") {
        if (options.engine_argument_count == options.engine_arguments.size()) {
          throw std::invalid_argument{"Too many engine arguments"};
        }

        options.engine_arguments[options.engine_argument_count++] = value();
      } else if (argument == "--no-session") {
        options.persist_session = false;
      } else if (argument == "--no-resume") {
        options.resume_agents = false;
      } else if (argument == "--no-config") {
        if (!options.config.empty()) {
          throw std::invalid_argument{"Conflicting configuration options"};
        }
        setFlag(options.no_config);
      } else if (argument == "--fresh") {
        setFlag(options.fresh);
      } else if (argument == "--background" || argument == "--daemonized") {
        if (options.mode != ServerMode::foreground) {
          throw std::invalid_argument{"Conflicting server modes"};
        }

        options.mode = argument == "--background" ? ServerMode::background : ServerMode::daemonized;
      } else {
        throw std::invalid_argument{"Unknown server option"};
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

private:
  inline static void setOnce(std::string_view &destination, std::string_view value) {
    if (!destination.empty() || value.empty()) {
      throw std::invalid_argument{"Duplicate or empty server option"};
    }

    destination = value;
  }

  inline static void setFlag(bool &flag) {
    if (flag) {
      throw std::invalid_argument{"Duplicate server option"};
    }

    flag = true;
  }
};

}
}

// Interface: telar_platform/runtime_paths.cppm
export {
namespace telar::runtime::cli {

template <EnvironmentLookup Environment>
struct DefaultSocketEnvironment {
  const Environment &source;

  inline std::string_view lookup(const char *name) const noexcept {
    const std::string_view key{name};
    return key == "TELAR_SOCKET" || key == "TELAR_SOCKET_PATH" ? std::string_view{} : source.lookup(name);
  }
};

template <Allocator Memory>
class RuntimePaths {
public:
  template <EnvironmentLookup Environment>
  inline explicit RuntimePaths(Memory &memory, const ServerOptions &options, const Environment &environment)
      : socket(AllocatorRef<char, Memory>{memory}),
        history(AllocatorRef<char, Memory>{memory}),
        session(AllocatorRef<char, Memory>{memory}),
        data_home(AllocatorRef<char, Memory>{memory}) {
    resolveSocket(options.socket, environment);
  }

  template <EnvironmentLookup Environment>
  inline void resolveStorage(const ServerOptions &options, const Environment &environment) {
    data_home = environment.lookup("XDG_DATA_HOME");
    if (const auto home = environment.lookup("HOME"); data_home.empty() && !home.empty()) {
      data_home = home;
      data_home += "/.local/share";
    }

    history = options.history.empty() ? environment.lookup("TELAR_HISTORY") : options.history;
    if (history.empty()) {
      if (data_home.empty()) {
        throw std::invalid_argument{"Home directory unavailable"};
      }

      history = data_home;
      history += "/telar/history.db";
      history_managed = true;
    }

    if (options.persist_session) {
      if (!options.session.empty()) {
        session = options.session;
      } else {
        session.assign(std::string_view{history}.substr(0, history.find_last_of('/') + 1));
        session += "session.ckpt";
      }
    }
  }

  inline void prepareSocket() const {
    if (socket_managed) {
      createPrivateDirectory(std::string_view{socket}.substr(0, socket.rfind('/')));
    }
  }

  template <EnvironmentLookup Environment>
  inline bool isDefaultSocket(const Environment &environment) const {
    const RuntimePaths expected{socket.get_allocator().memory(), ServerOptions{}, DefaultSocketEnvironment<Environment>{environment}};
    return socket == expected.socket;
  }

  inline void prepareStorage() const {
    if (history_managed) {
      createPrivateDirectory(std::string_view{history}.substr(0, history.rfind('/')));
    }
  }

  String<Memory> socket;
  String<Memory> history;
  String<Memory> session;
  // XDG_DATA_HOME, or ~/.local/share; empty without either.
  String<Memory> data_home;
  bool socket_managed = false;
  bool history_managed = false;

private:
  template <EnvironmentLookup Environment>
  inline void resolveSocket(std::string_view override, const Environment &environment) {
    for (const auto candidate : {override, environment.lookup("TELAR_SOCKET"), environment.lookup("TELAR_SOCKET_PATH")}) {
      if (!candidate.empty()) {
        socket = candidate;
        validateSocket();
        return;
      }
    }

    socket_managed = true;
    if (const auto runtime_directory = environment.lookup("XDG_RUNTIME_DIR"); !runtime_directory.empty()) {
      socket = runtime_directory;
      appendSocketDirectory("telar");
    } else {
      const auto temporary_directory = environment.lookup("TMPDIR");
      socket = temporary_directory.empty() ? "/tmp" : temporary_directory;
      std::array<char, 32> name;
      constexpr std::string_view prefix = "telar-";
      std::copy(prefix.begin(), prefix.end(), name.begin());
      const auto converted = std::to_chars(name.data() + prefix.size(), name.data() + name.size(), ::getuid());
      appendSocketDirectory({name.data(), converted.ptr});
    }

    validateSocket();
  }

  inline void appendSocketDirectory(std::string_view name) {
    if (socket.back() != '/') {
      socket.push_back('/');
    }

    socket += name;
    socket += "/runtime.sock";
  }

  inline void validateSocket() const {
    if (socket.empty() || socket.front() != '/' || socket.size() >= sizeof(sockaddr_un::sun_path) || socket.back() == '/' || socket.contains('\0')) {
      throw std::invalid_argument{"Invalid absolute runtime socket path"};
    }
  }
};

template <Allocator Memory, EnvironmentLookup Environment>
RuntimePaths(Memory &memory, const ServerOptions &options, const Environment &environment) -> RuntimePaths<Memory>;

}
}

// Interface: telar_platform/spawn_options.cppm
export {
namespace telar::runtime {

inline void checkSpawn(int result) {
  if (result != 0) {
    throw SystemError{"Prepare child process", result};
  }
}

class SpawnOptions {
public:
  inline explicit SpawnOptions(short flags) {
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
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    checkSpawn(posix_spawnattr_setflags(&attributes, flags | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK));
  }

  inline ~SpawnOptions() {
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
  }

  SpawnOptions(const SpawnOptions &) = delete;
  SpawnOptions &operator=(const SpawnOptions &) = delete;

  inline void redirect(int source, int destination) {
    checkSpawn(posix_spawn_file_actions_adddup2(&actions, source, destination));
  }

  inline void changeDirectory(const char *path) {
#if defined(__APPLE__)
    checkSpawn(::posix_spawn_file_actions_addchdir(&actions, path));
#else
    checkSpawn(::posix_spawn_file_actions_addchdir_np(&actions, path));
#endif
  }

  // The child keeps only the standard streams and what `redirect` placed.
  // musl has no addclosefrom, so there every descriptor above stderr is
  // marked close-on-exec in this process instead: the child loses it at
  // exec, this process keeps it, and dup2 targets are fresh descriptors.
  inline void closeOthers() {
#if defined(__GLIBC__)
    checkSpawn(::posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1));
#elif defined(__linux__)
    DIR *descriptors = ::opendir("/proc/self/fd");
    if (descriptors == nullptr) {
      throw SystemError{"List open descriptors"};
    }

    const int own = ::dirfd(descriptors);
    while (const auto *entry = ::readdir(descriptors)) {
      char *end = nullptr;
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

  posix_spawnattr_t attributes{};
  posix_spawn_file_actions_t actions{};
};

}
}

// Interface: telar_platform/daemon.cppm
export {

namespace telar::runtime::cli {

FileDescriptor openStartLog(const char *path) noexcept;
pid_t spawnDaemon(const char *executable, char *const *arguments, const char *log_path);

template <Allocator Memory>
pid_t launchDaemon(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths, const ExecutablePath &executable) {
  std::array<char, PATH_MAX> config_path;
  Vector<char *, Memory> arguments{AllocatorRef<char *, Memory>{memory}};
  arguments.reserve(2 * options.engine_argument_count + 28);
  const auto append = [&](std::string_view value) { arguments.push_back(const_cast<char *>(value.data())); };
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
    if (::realpath(options.config.data(), config_path.data()) == nullptr) {
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
  for (const auto [enabled, flag] : std::array<std::pair<bool, std::string_view>, 4>{{{options.no_config, "--no-config"}, {options.fresh, "--fresh"}, {!options.persist_session, "--no-session"}, {!options.resume_agents, "--no-resume"}}}) {
    if (enabled) {
      append(flag);
    }
  }

  arguments.push_back(nullptr);
  String<Memory> log_path{paths.socket, AllocatorRef<char, Memory>{memory}};
  log_path += ".runtime.start.log";
  return spawnDaemon(executable.c_str(), arguments.data(), log_path.c_str());
}

}
}

// Interface: telar_platform/directory_stream.cppm
export {
namespace telar::runtime {

class DirectoryStream {
public:
  inline explicit DirectoryStream(int directory)
      : DirectoryStream(FileDescriptor{::openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)}) {}

  inline explicit DirectoryStream(FileDescriptor iterator) {
    if (!iterator) {
      throw SystemError{"Open directory iterator"};
    }

    stream_ = ::fdopendir(iterator.get());
    if (stream_ == nullptr) {
      throw SystemError{"Create directory iterator"};
    }
    iterator.release();
  }

  inline ~DirectoryStream() { ::closedir(stream_); }

  DirectoryStream(const DirectoryStream &) = delete;
  DirectoryStream &operator=(const DirectoryStream &) = delete;

  inline int descriptor() const noexcept { return ::dirfd(stream_); }

  inline const dirent *next() {
    for (;;) {
      errno = 0;
      const auto *entry = ::readdir(stream_);
      if (entry == nullptr) {
        if (errno != 0) {
          throw SystemError{"Read directory entry"};
        }
        return nullptr;
      }

      const auto *name = entry->d_name;
      const bool current_directory = name[0] == '.' && name[1] == '\0';
      const bool parent_directory = name[0] == '.' && name[1] == '.' && name[2] == '\0';
      if (!current_directory && !parent_directory) {
        return entry;
      }
    }
  }

private:
  DIR *stream_;
};

}
}

// Interface: telar_platform/read_regular_file.cppm
export {
namespace telar::runtime {

inline tbc::view<std::optional<std::string_view>, tbc::lt::a> readRegularFile(std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
  std::array<char, PATH_MAX> terminated;
  if (path.size() >= terminated.size() || path.contains('\0')) {
    return std::nullopt;
  }

  std::memcpy(terminated.data(), path.data(), path.size());
  terminated[path.size()] = '\0';
  FileDescriptor file{::open(terminated.data(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)};
  struct stat status{};
  if (!file || ::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode)) {
    return std::nullopt;
  }

  std::size_t length = 0;
  while (length < buffer.size()) {
    const auto count = ::read(file.get(), buffer.data() + length, buffer.size() - length);
    if (count > 0) {
      length += static_cast<std::size_t>(count);
    } else if (count == 0) {
      break;
    } else if (errno != EINTR) {
      return std::nullopt;
    }
  }

  return std::string_view{buffer.data(), length};
}

}
}

// Interface: telar_platform/git_files.cppm
export {
namespace telar::runtime {

class GitFiles {
public:
  inline static tbc::view<std::optional<std::string_view>, tbc::lt::a> join(std::string_view directory, std::string_view suffix, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    while (directory.ends_with('/')) {
      directory.remove_suffix(1);
    }
    const auto length = directory.size() + 1 + suffix.size();
    if (length >= buffer.size()) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), directory.data(), directory.size());
    buffer[directory.size()] = '/';
    std::memcpy(buffer.data() + directory.size() + 1, suffix.data(), suffix.size());
    buffer[length] = '\0';
    return std::string_view{buffer.data(), length};
  }

  inline static tbc::view<std::optional<std::string_view>, tbc::lt::a> resolve(std::string_view directory, std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    if (path.empty() || path.contains('\0')) {
      return std::nullopt;
    }
    if (!path.starts_with('/')) {
      return join(directory, path, buffer);
    }
    if (path.size() >= buffer.size()) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), path.data(), path.size());
    buffer[path.size()] = '\0';
    return std::string_view{buffer.data(), path.size()};
  }

  inline static tbc::view<std::optional<std::string_view>, tbc::lt::a> directory(std::string_view root, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    std::array<char, PATH_MAX> path;
    const auto dot_git = join(root, ".git", path);
    std::array<char, PATH_MAX + 16> bytes;
    const auto pointer = dot_git ? readRegularFile(*dot_git, bytes) : std::nullopt;
    if (!pointer) {
      return std::nullopt;
    }

    const auto contents = trim(*pointer, " \t\r\n");
    constexpr std::string_view prefix = "gitdir:";
    if (!contents.starts_with(prefix)) {
      return std::nullopt;
    }

    return resolve(root, trim(contents.substr(prefix.size()), " \t"), buffer);
  }

  inline static tbc::view<std::string_view, tbc::lt::a> trim(tbc::view<std::string_view, tbc::lt::a> value, std::string_view characters) noexcept {
    const auto first = value.find_first_not_of(characters);
    if (first == std::string_view::npos) {
      return {};
    }

    return value.substr(first, value.find_last_not_of(characters) - first + 1);
  }
};

}
}

// Interface: telar_platform/git_head.cppm
export {
namespace telar::runtime {

class GitHead {
public:
  inline std::optional<std::string_view> read(std::string_view root) noexcept {
    const auto direct = GitFiles::join(root, ".git/HEAD", path_);
    if (!direct) {
      return std::nullopt;
    }
    if (const auto contents = readRegularFile(*direct, head_)) {
      return parse(*contents);
    }

    std::array<char, PATH_MAX> resolved;
    const auto directory = GitFiles::directory(root, resolved);
    if (!directory) {
      return std::nullopt;
    }

    const auto linked = GitFiles::join(*directory, "HEAD", path_);
    const auto head = linked ? readRegularFile(*linked, head_) : std::nullopt;
    return head ? std::optional{parse(*head)} : std::nullopt;
  }

  inline static std::string_view parse(std::string_view contents) noexcept {
    contents = GitFiles::trim(contents, " \r\n");
    constexpr std::string_view reference = "ref:";
    constexpr std::string_view branch = "refs/heads/";
    if (contents.starts_with(reference)) {
      contents = GitFiles::trim(contents.substr(reference.size()), " ");
      return contents.starts_with(branch) ? contents.substr(branch.size()) : contents;
    }

    constexpr std::size_t abbreviated_hash_length = 8;
    return contents.substr(0, abbreviated_hash_length);
  }

private:
  std::array<char, PATH_MAX> path_;
  std::array<char, 4096> head_;
};

}
}

// Interface: telar_platform/git_observation_policy.cppm
export {
namespace telar::runtime {

struct GitRepositoryFacts {
  static constexpr std::size_t maximum_drivers = 8;
  std::array<std::string_view, maximum_drivers> drivers;
  std::size_t driver_count = 0;
  bool may_fetch = false;

  inline static std::optional<GitRepositoryFacts> parse(std::string_view listing) noexcept {
    GitRepositoryFacts facts;
    while (!listing.empty()) {
      const auto scope_end = listing.find('\0');
      if (scope_end == 0) {
        break;
      }
      if (scope_end == std::string_view::npos) {
        return std::nullopt;
      }

      const auto scope = listing.substr(0, scope_end);
      listing.remove_prefix(scope_end + 1);
      const auto entry_end = listing.find('\0');
      if (entry_end == std::string_view::npos) {
        return std::nullopt;
      }
      const auto entry = listing.substr(0, entry_end);
      listing.remove_prefix(entry_end + 1);
      if (scope != "local" && scope != "worktree") {
        continue;
      }

      const auto key = entry.substr(0, entry.find('\n'));
      if (key == "extensions.partialclone" || (key.starts_with("remote.") && (key.ends_with(".promisor") || key.ends_with(".partialclonefilter") || key.ends_with(".uploadpack")))) {
        facts.may_fetch = true;
        continue;
      }

      constexpr std::string_view prefix = "filter.";
      const auto variable = key.rfind('.');
      if (!key.starts_with(prefix) || variable < prefix.size()) {
        continue;
      }
      const auto driver = key.substr(prefix.size(), variable - prefix.size());
      if (driver.find_first_of("=\n") != std::string_view::npos) {
        return std::nullopt;
      }

      bool known = false;
      for (std::size_t index = 0; index < facts.driver_count; ++index) {
        known |= facts.drivers[index] == driver;
      }
      if (!known) {
        if (facts.driver_count == maximum_drivers) {
          return std::nullopt;
        }
        facts.drivers[facts.driver_count++] = driver;
      }
    }

    return facts;
  }
};

inline constexpr auto git_observation_options = std::to_array<std::string_view>({
    "git",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "hook.applypatch-msg.enabled=false",
    "-c",
    "hook.pre-applypatch.enabled=false",
    "-c",
    "hook.post-applypatch.enabled=false",
    "-c",
    "hook.pre-commit.enabled=false",
    "-c",
    "hook.pre-merge-commit.enabled=false",
    "-c",
    "hook.prepare-commit-msg.enabled=false",
    "-c",
    "hook.commit-msg.enabled=false",
    "-c",
    "hook.post-commit.enabled=false",
    "-c",
    "hook.pre-rebase.enabled=false",
    "-c",
    "hook.post-checkout.enabled=false",
    "-c",
    "hook.post-merge.enabled=false",
    "-c",
    "hook.pre-push.enabled=false",
    "-c",
    "hook.pre-receive.enabled=false",
    "-c",
    "hook.update.enabled=false",
    "-c",
    "hook.proc-receive.enabled=false",
    "-c",
    "hook.post-receive.enabled=false",
    "-c",
    "hook.post-update.enabled=false",
    "-c",
    "hook.reference-transaction.enabled=false",
    "-c",
    "hook.push-to-checkout.enabled=false",
    "-c",
    "hook.pre-auto-gc.enabled=false",
    "-c",
    "hook.post-rewrite.enabled=false",
    "-c",
    "hook.sendemail-validate.enabled=false",
    "-c",
    "hook.fsmonitor-watchman.enabled=false",
    "-c",
    "hook.post-index-change.enabled=false",
});

}
}

// Interface: telar_platform/graphics/shared_image_storage.cppm
export {
namespace telar::runtime {

class SharedImageStorage {
public:
  using Name = std::array<char, 32>;

  inline static std::optional<SharedImageStorage> create(std::size_t length) noexcept {
    if (length == 0 || length > static_cast<std::size_t>(std::numeric_limits<off_t>::max())) {
      return std::nullopt;
    }

    SharedImageStorage storage;
    std::array<std::uint64_t, 2> nonce;
    randomBytes(nonce.data(), sizeof(nonce));
    std::snprintf(storage.name_.data(), storage.name_.size(), "/tlr%016llx%08x", static_cast<unsigned long long>(nonce[0]), static_cast<unsigned>(nonce[1]));
    FileDescriptor descriptor{::shm_open(storage.name_.data(), O_CREAT | O_EXCL | O_RDWR, 0600)};
    if (!descriptor) {
      storage.name_[0] = '\0';
      return std::nullopt;
    }
    if (::ftruncate(descriptor.get(), static_cast<off_t>(length)) != 0) {
      return std::nullopt;
    }

    storage.mapping_ = MappedRegion{descriptor.get(), length, PROT_READ | PROT_WRITE};
    if (!storage.mapping_) {
      return std::nullopt;
    }
    return storage;
  }

  inline ~SharedImageStorage() {
    if (name_[0] != '\0') {
      ::shm_unlink(name_.data());
    }
  }

  SharedImageStorage(const SharedImageStorage &) = delete;
  SharedImageStorage &operator=(const SharedImageStorage &) = delete;

  inline SharedImageStorage(SharedImageStorage &&other) noexcept
      : name_(other.takeName()),
        mapping_(std::move(other.mapping_)) {}

  inline MappedRegion &mapping() noexcept {
    return mapping_;
  }

  inline Name takeName() noexcept {
    auto name = name_;
    name_[0] = '\0';
    return name;
  }

private:
  SharedImageStorage() noexcept = default;

  Name name_{};
  MappedRegion mapping_;
};

}
}

// Interface: telar_platform/linked_worktree.cppm
export {
namespace telar::runtime {

class LinkedWorktree {
public:
  struct Found {
    std::size_t root_length;
    std::string_view branch;
  };

  inline std::optional<Found> find(std::string_view directory) noexcept {
    if (!directory.starts_with('/') || directory.contains('\0')) {
      return std::nullopt;
    }

    constexpr unsigned maximum_depth = 64;
    for (unsigned depth = 0; depth < maximum_depth; ++depth) {
      const auto dot_git = GitFiles::join(directory, ".git", path_);
      if (!dot_git) {
        return std::nullopt;
      }
      struct stat status{};
      if (::stat(dot_git->data(), &status) == 0) {
        if (S_ISDIR(status.st_mode)) {
          return std::nullopt;
        }
        const auto branch = linkedBranch(directory);
        return branch ? std::optional{Found{directory.size(), *branch}} : std::nullopt;
      }

      while (directory.size() > 1 && directory.ends_with('/')) {
        directory.remove_suffix(1);
      }
      const auto separator = directory.rfind('/');
      if (directory.size() <= 1 || separator == std::string_view::npos) {
        return std::nullopt;
      }
      directory = directory.substr(0, std::max<std::size_t>(1, separator));
    }

    return std::nullopt;
  }

  inline std::optional<std::string_view> mainBranch(std::string_view root) noexcept {
    std::array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory);
    if (!directory) {
      return std::nullopt;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_);
    std::array<char, PATH_MAX> contents;
    const auto common = common_path ? readRegularFile(*common_path, contents) : std::nullopt;
    std::array<char, PATH_MAX> resolved;
    const auto common_directory = common ? GitFiles::resolve(*directory, GitFiles::trim(*common, " \t\r\n"), resolved) : std::nullopt;
    const auto head_path = common_directory ? GitFiles::join(*common_directory, "HEAD", path_) : std::nullopt;
    const auto head = head_path ? readRegularFile(*head_path, head_) : std::nullopt;
    if (!head) {
      return std::nullopt;
    }

    const auto text = GitFiles::trim(*head, " \r\n");
    constexpr std::string_view prefix = "ref: refs/heads/";
    return text.starts_with(prefix) && text.size() > prefix.size() ? std::optional{text.substr(prefix.size())} : std::nullopt;
  }

private:
  inline std::optional<std::string_view> linkedBranch(std::string_view root) noexcept {
    std::array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory);
    if (!directory) {
      return std::nullopt;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_);
    std::array<char, PATH_MAX> common;
    if (!common_path || !readRegularFile(*common_path, common)) {
      return std::nullopt;
    }
    const auto head_path = GitFiles::join(*directory, "HEAD", path_);
    const auto head = head_path ? readRegularFile(*head_path, head_) : std::nullopt;
    if (!head) {
      return std::nullopt;
    }

    const auto branch = GitHead::parse(*head);
    return branch.empty() ? std::nullopt : std::optional{branch};
  }

  std::array<char, PATH_MAX> path_;
  std::array<char, 256> head_;
};

}
}

// Interface: telar_platform/observation_time.cppm
export {
namespace telar::runtime {

struct ObservationTime {
  std::int64_t milliseconds = 0;
  std::int64_t nanoseconds = 0;

  inline static ObservationTime now() noexcept {
    return {std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count(), std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()};
  }

  inline bool before(ObservationTime other) const noexcept {
    return nanoseconds != 0 && other.nanoseconds != 0 ? nanoseconds < other.nanoseconds : milliseconds < other.milliseconds;
  }
};

}
}

// Interface: telar_platform/open_beneath.cppm
export {
namespace telar::runtime {

inline FileDescriptor openBeneath(int root, std::string_view path, int flags, mode_t permissions = 0) {
  if (path.empty() || path.front() == '/' || path.size() >= PATH_MAX || path.contains('\0')) {
    throw SystemError{"Invalid package-relative path", EINVAL};
  }

  FileDescriptor parent;
  std::array<char, PATH_MAX> name;
  for (;;) {
    const auto separator = path.find('/');
    const auto component = path.substr(0, separator);
    if (component.empty() || component == "." || component == "..") {
      throw SystemError{"Invalid package-relative component", EINVAL};
    }
    std::copy(component.begin(), component.end(), name.begin());
    name[component.size()] = '\0';

    const auto selected_flags = separator == std::string_view::npos ? flags : O_RDONLY | O_DIRECTORY;
    FileDescriptor selected{::openat(parent ? parent.get() : root, name.data(), selected_flags | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC, permissions)};
    if (!selected) {
      throw SystemError{"Open package-relative file"};
    }
    if (separator == std::string_view::npos) {
      return selected;
    }

    parent = std::move(selected);
    path.remove_prefix(separator + 1);
  }
}

}
}

// Interface: telar_platform/peer_credentials.cppm
export {
namespace telar::runtime {

struct PeerCredentials {
  uid_t user;
  gid_t group;
};

inline std::optional<PeerCredentials> peerCredentials(int socket) noexcept {
#if defined(__APPLE__)
  PeerCredentials credentials{};
  if (::getpeereid(socket, &credentials.user, &credentials.group) != 0) {
    return std::nullopt;
  }
  return credentials;
#else
  ucred credentials{};
  socklen_t length = sizeof(credentials);
  if (::getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0 || length != sizeof(credentials)) {
    return std::nullopt;
  }
  return PeerCredentials{credentials.uid, credentials.gid};
#endif
}

}
}

// Interface: telar_platform/private_file.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
bool readPrivateFile(int directory, std::string_view name, Vector<unsigned char, Memory> &bytes, std::size_t limit) {
  if (name.empty() || name.size() >= PATH_MAX || name.contains('\0')) {
    throw SystemError{"Invalid private file path", EINVAL};
  }

  std::array<char, PATH_MAX> terminated;
  std::copy(name.begin(), name.end(), terminated.begin());
  terminated[name.size()] = '\0';
  FileDescriptor file{::openat(directory, terminated.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
  if (!file) {
    if (errno == ENOENT) {
      return false;
    }
    throw SystemError{"Open private file"};
  }

  struct stat state{};
  if (::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
    throw SystemError{"Validate private file", EACCES};
  }
  if (state.st_size < 0 || static_cast<std::uint64_t>(state.st_size) > limit) {
    throw SystemError{"Private file exceeds its limit", EFBIG};
  }

  bytes.resize(static_cast<std::size_t>(state.st_size));
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const auto count = ::read(file.get(), bytes.data() + offset, bytes.size() - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      throw SystemError{"Private file changed while reading", EIO};
    }
    offset += static_cast<std::size_t>(count);
  }

  unsigned char extra;
  ssize_t count;
  do {
    count = ::read(file.get(), &extra, 1);
  } while (count < 0 && errno == EINTR);
  if (count != 0) {
    throw SystemError{"Private file changed while reading", EIO};
  }
  return true;
}

}
}

// Interface: telar_platform/read_file.cppm
export {
namespace telar::runtime {

enum class FileReadFailure {
  invalid_size,
  changed
};

class FileReadError : public std::exception {
public:
  inline explicit FileReadError(FileReadFailure failure) noexcept : failure_(failure) {}

  inline FileReadFailure failure() const noexcept { return failure_; }

  inline const char *what() const noexcept override {
    return failure_ == FileReadFailure::invalid_size ? "Source must be a bounded regular file" : "Source changed while reading";
  }

private:
  FileReadFailure failure_;
};

template <Allocator Memory>
String<Memory> readFileContents(Memory &memory, int descriptor, std::size_t maximum_bytes) {
  struct stat metadata{};
  if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 || static_cast<std::uint64_t>(metadata.st_size) > maximum_bytes) {
    throw FileReadError{FileReadFailure::invalid_size};
  }

  String<Memory> source{AllocatorRef<char, Memory>{memory}};
  source.resize(static_cast<std::size_t>(metadata.st_size));
  std::size_t offset = 0;
  while (offset < source.size()) {
    const auto count = ::read(descriptor, source.data() + offset, source.size() - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      throw FileReadError{FileReadFailure::changed};
    }

    offset += static_cast<std::size_t>(count);
  }

  char extra;
  ssize_t extra_count;
  do {
    extra_count = ::read(descriptor, &extra, 1);
  } while (extra_count < 0 && errno == EINTR);
  if (extra_count != 0) {
    throw FileReadError{FileReadFailure::changed};
  }

  return source;
}

template <Allocator Memory>
String<Memory> readFile(Memory &memory, const char *path, std::size_t maximum_bytes) {
  FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY)};
  if (!file) {
    throw SystemError{"Open source file"};
  }
  return readFileContents(memory, file.get(), maximum_bytes);
}

}
}

// Interface: telar_platform/rename.cppm
export {
#if defined(__linux__) && !defined(__GLIBC__)
#endif

namespace telar::runtime {

enum class RenameMode { create_only, replace };

inline int renameAt(int source_directory, const char *source, int destination_directory, const char *destination, RenameMode mode) noexcept {
#if defined(__APPLE__)
  const auto flags = mode == RenameMode::create_only ? RENAME_EXCL : 0;
  return ::renameatx_np(source_directory, source, destination_directory, destination, flags);
#elif defined(__GLIBC__)
  const auto flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
  return ::renameat2(source_directory, source, destination_directory, destination, flags);
#else
  // musl declares no renameat2; the kernel call is the same.
  const unsigned flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
  return static_cast<int>(::syscall(SYS_renameat2, source_directory, source, destination_directory, destination, flags));
#endif
}

}
}

// Interface: telar_platform/resolve_relative_path.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
void resolveRelativePath(String<Memory> &path, std::string_view directory) {
  if (path.empty() || path.front() == '/') {
    return;
  }

  String<Memory> combined{directory, path.get_allocator()};
  combined += '/';
  combined += path;
  path.clear();
  std::string_view remaining{combined};
  while (!remaining.empty()) {
    const auto end = remaining.find('/');
    const auto component = remaining.substr(0, end);
    if (component == "..") {
      const auto slash = path.rfind('/');
      path.resize(slash == String<Memory>::npos ? 0 : slash);
    } else if (!component.empty() && component != ".") {
      path += '/';
      path += component;
    }
    if (end == std::string_view::npos) {
      break;
    }

    remaining.remove_prefix(end + 1);
  }

  if (path.empty()) {
    path = "/";
  }
}

template <Allocator Memory>
void resolveAbsolutePath(String<Memory> &path) {
  if (path.starts_with('/')) {
    return;
  }
  std::array<char, PATH_MAX> directory;
  if (::getcwd(directory.data(), directory.size()) == nullptr) {
    throw SystemError{"Resolve working directory"};
  }
  resolveRelativePath(path, directory.data());
}

}
}

// Interface: telar_platform/sha256.cppm
export {
namespace telar::runtime {

class Sha256 {
public:
  inline Sha256() noexcept { SHA256_Init(&context_); }

  inline void update(std::string_view bytes) noexcept {
    SHA256_Update(&context_, bytes.data(), bytes.size());
  }

  inline std::array<std::uint8_t, SHA256_DIGEST_LENGTH> finish() noexcept {
    std::array<std::uint8_t, SHA256_DIGEST_LENGTH> digest;
    SHA256_Final(digest.data(), &context_);
    return digest;
  }

private:
  SHA256_CTX context_;
};

}
}

// Interface: telar_platform/socket_signals.cppm
export {
namespace telar::runtime {

inline void suppressSocketSignals(int descriptor) {
#if defined(SO_NOSIGPIPE)
  const int enabled = 1;
  if (::setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
    throw SystemError{"Disable socket SIGPIPE"};
  }
#else
  (void)descriptor;
  if (::signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
    throw SystemError{"Disable socket SIGPIPE"};
  }
#endif
}

}
}

// Interface: telar_platform/temporary_directory.cppm
export {
namespace telar::runtime {

class TemporaryDirectory {
public:
  inline explicit TemporaryDirectory(std::string_view pattern) {
    if (pattern.empty() || pattern.front() != '/' || !pattern.ends_with("XXXXXX") || pattern.size() >= path_.size() || pattern.contains('\0')) {
      throw SystemError{"Invalid temporary directory pattern", EINVAL};
    }

    std::copy(pattern.begin(), pattern.end(), path_.begin());
    path_[pattern.size()] = '\0';
    if (::mkdtemp(path_.data()) == nullptr) {
      throw SystemError{"Create temporary directory"};
    }
    directory_.reset(::open(path_.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (!directory_ || ::fstat(directory_.get(), &identity_) != 0 || ::fchmod(directory_.get(), 0700) != 0) {
      const auto error = errno;
      ::rmdir(path_.data());
      throw SystemError{"Open temporary directory", error};
    }
    length_ = pattern.size();
  }

  inline ~TemporaryDirectory() {
    removeContents(directory_.get());
    struct stat current{};
    if (::lstat(path_.data(), &current) == 0 && current.st_dev == identity_.st_dev && current.st_ino == identity_.st_ino) {
      ::rmdir(path_.data());
    }
  }

  TemporaryDirectory(const TemporaryDirectory &) = delete;
  TemporaryDirectory &operator=(const TemporaryDirectory &) = delete;

  inline int descriptor() const noexcept { return directory_.get(); }
  inline std::string_view path() const noexcept { return {path_.data(), length_}; }

private:
  inline static void removeContents(int directory) noexcept {
    try {
      DirectoryStream iterator{directory};
      while (const auto *entry = iterator.next()) {
        FileDescriptor child{::openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (child) {
          removeContents(child.get());
          ::unlinkat(directory, entry->d_name, AT_REMOVEDIR);
        } else {
          ::unlinkat(directory, entry->d_name, 0);
        }
      }
    } catch (...) {
    }
  }

  std::array<char, PATH_MAX> path_;
  std::size_t length_ = 0;
  FileDescriptor directory_;
  struct stat identity_{};
};

}
}

// Interface: telar_platform/thread_identity.cppm
export {
namespace telar::runtime {

inline std::uint64_t currentThreadId() noexcept {
#if defined(__APPLE__)
  std::uint64_t identity = 0;
  ::pthread_threadid_np(nullptr, &identity);
  return identity;
#else
  return static_cast<std::uint64_t>(::gettid());
#endif
}

}
}

// Interface: telar_platform/thread_name.cppm
export {
namespace telar::runtime {

inline void setThreadName(const char *name) noexcept {
#if defined(__APPLE__)
  ::pthread_setname_np(name);
#else
  ::pthread_setname_np(::pthread_self(), name);
#endif
}

}
}

// Interface: telar_platform/write_descriptor.cppm
export {
namespace telar::runtime {

inline int writeDescriptor(int descriptor, std::span<const std::uint8_t> bytes) noexcept {
  while (!bytes.empty()) {
    const auto count = ::write(descriptor, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      return count == 0 ? EIO : errno;
    }

    bytes = bytes.subspan(static_cast<std::size_t>(count));
  }
  return 0;
}

}
}

// Interface: telar_platform/write_private_file.cppm
export {
namespace telar::runtime {

using PrivateFileMode = RenameMode;

inline int writePrivateFile(int directory, std::string_view name, std::span<const std::uint8_t> bytes, PrivateFileMode mode) noexcept {
  if (name.empty() || name.size() > NAME_MAX || name.contains('\0') || name.contains('/') || name == "." || name == "..") {
    return EINVAL;
  }

  std::array<char, NAME_MAX + 1> destination;
  std::copy(name.begin(), name.end(), destination.begin());
  destination[name.size()] = '\0';
  constexpr unsigned maximum_attempts = 8;
  for (unsigned attempt = 0; attempt < maximum_attempts; ++attempt) {
    std::uint64_t nonce;
    randomBytes(&nonce, sizeof(nonce));
    std::array<char, 64> temporary;
    std::snprintf(temporary.data(), temporary.size(), ".telar-write-%016llx.tmp", static_cast<unsigned long long>(nonce));
    FileDescriptor file{::openat(directory, temporary.data(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)};
    if (!file) {
      if (errno == EEXIST) {
        continue;
      }
      return errno;
    }

    const int written = writeDescriptor(file.get(), bytes);
    if (written != 0 || ::fsync(file.get()) != 0) {
      const int failure = written != 0 ? written : errno;
      file.reset();
      ::unlinkat(directory, temporary.data(), 0);
      return failure;
    }
    file.reset();

    if (renameAt(directory, temporary.data(), directory, destination.data(), mode) != 0) {
      const int failure = errno;
      ::unlinkat(directory, temporary.data(), 0);
      return failure;
    }
    return 0;
  }
  return EEXIST;
}

}
}
