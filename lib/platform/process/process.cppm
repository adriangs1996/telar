module;
#include "tbc/view.hpp"

#include "telar_platform/process_environment.h"

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if (defined(__APPLE__))
#include <libproc.h>
#include <mach-o/dyld.h>
#include <sys/attr.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/close_range.h>
#include <sys/syscall.h>
#endif

export module telar.platform.process;

import std;

export import telar.base.memory.allocators;
export import telar.base.memory.containers;
export import telar.base.memory.sensitive;

import telar.base.text;
import telar.platform.error;
import telar.platform.primitives;
import telar.vocabulary;

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

// Interface: telar_platform/pty_process.cppm
export {
  namespace telar::runtime {

    struct SpawnSpec {
      const char* executable;
      const char* cwd;
      char* const* arguments;
      char* const* environment;
      TerminalSize size;
    };

    class PtyProcess {
    public:
      explicit PtyProcess(const SpawnSpec& specification);
      ~PtyProcess();
      PtyProcess(const PtyProcess&) = delete;
      PtyProcess& operator=(const PtyProcess&) = delete;

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

// Interface: telar_platform/shell_exit_code.cppm
export {
  namespace telar::runtime {

    // A wait status as a shell reports it in $?: the exit status, or 128 plus the killing signal.
    constexpr int shellExitCode(int status) noexcept {
      constexpr int signal_exit_offset = 128;

      return WIFEXITED(status) ? WEXITSTATUS(status) : signal_exit_offset + WTERMSIG(status);
    }

  }
}

// Interface: telar_platform/command.cppm
export {
  namespace telar::runtime {

    // Where exec finds `program` along `path`, a colon-separated directory list: the first
    // `directory/program` this process may execute, written to `found` with its terminator. A
    // relative directory, the empty one included, is relative to `cwd`, or to this process's
    // working directory when `cwd` is empty. A candidate longer than PATH_MAX is passed over.
    inline bool findExecutable(std::string_view path, std::string_view program, std::span<char, PATH_MAX> found, std::string_view cwd = {}) noexcept {
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

    enum class CommandPurpose {
      terminal,
      administration,
      configured_helper,
    };

    template <Allocator Memory>
    class Command {
    public:
      // Copies the launch; it keeps only its allocator, region `a`.
      inline explicit Command(tbc::view<Memory&, tbc::lt::a> memory, const Launch& launch, CommandPurpose purpose = CommandPurpose::terminal)
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
          const char* shell = std::getenv("SHELL");

          arguments_.emplace_back(shell != nullptr ? shell : "/bin/sh", AllocatorRef<char, Memory>{memory});
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

      Command(const Command&) = delete;
      Command& operator=(const Command&) = delete;

      inline void removeEnvironmentPrefix(std::string_view prefix) {
        std::erase_if(environment_, [prefix](const auto& entry) {
          return entry.starts_with(prefix);
        });
      }

      inline std::optional<std::string_view> environment(std::string_view name) const noexcept {
        for (const auto& entry : environment_) {
          if (definesVariable(entry, name)) {
            return std::string_view{entry}.substr(name.size() + 1);
          }
        }

        return std::nullopt;
      }

      inline void removeEnvironment(std::string_view name) {
        std::erase_if(environment_, [name](auto& entry) {
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

      inline SpawnSpec specification(TerminalSize size) {
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

      using SensitiveMemory = ErasingAllocator<Memory>;
      tbc::view<String<Memory>, tbc::lt::a> executable_;
      tbc::view<String<Memory>, tbc::lt::a> cwd_;
      tbc::view<Vector<String<Memory>, Memory>, tbc::lt::a> arguments_;
      tbc::view<Vector<String<Memory>, Memory>, tbc::lt::a> spawn_arguments_;
      tbc::view<SensitiveMemory, tbc::lt::a> environment_memory_;
      // The environment allocates from the sibling allocator, and the spawn arrays point into the
      // command's own strings, so a command keeps its address.
      tbc::view<Vector<String<SensitiveMemory>, SensitiveMemory>, tbc::lt::self> environment_;
      tbc::view<Vector<char*, Memory>, tbc::lt::self> argument_pointers_;
      tbc::view<Vector<char*, Memory>, tbc::lt::self> environment_pointers_;
      tbc::view<Memory&, tbc::lt::a> memory_;
      bool restorable_;
    };

    template <Allocator Memory>
    Command(Memory& memory, const Launch& launch, CommandPurpose purpose = CommandPurpose::terminal) -> Command<Memory>;

  }
}

// Interface: telar_platform/pipe_process.cppm
export {
  namespace telar::runtime {

    enum class ProcessInput {
      pipe,
      buffered_socket,
    };

    class PipeProcess {
    public:
      explicit PipeProcess(const SpawnSpec& specification, ProcessInput input = ProcessInput::pipe);
      ~PipeProcess();
      PipeProcess(const PipeProcess&) = delete;
      PipeProcess& operator=(const PipeProcess&) = delete;

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

      inline explicit CommandOutput(Memory& memory, std::size_t limit, const std::atomic<bool>* cancelled = nullptr)
          : output_(memory, limit),
            limit_(limit),
            cancelled_(cancelled) {}

      inline int run(Command<Memory>& command, Clock::time_point deadline, bool retain_prefix = false, const std::atomic<bool>* cancelled = nullptr) {
        return execute(command, deadline, ExecutionOptions{.cancelled = cancelled}, [&](std::span<const Byte> bytes) {
          return append(bytes, retain_prefix);
        });
      }

      inline int runWithInput(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input) {
        return execute(command, deadline, ExecutionOptions{.input = input}, [&](std::span<const Byte> bytes) {
          return append(bytes, true);
        });
      }

      template <typename ErrorConsumer>
      inline int runWithInputDiagnostics(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input, ErrorConsumer&& error) {
        return execute(command, deadline, ExecutionOptions{.input = input}, [&](std::span<const Byte> bytes) {
          return append(bytes, true);
        },
            error);
      }

      template <typename Consumer>
      inline int stream(Command<Memory>& command, Clock::time_point deadline, Consumer&& consume) {
        return execute(command, deadline, ExecutionOptions{}, consume);
      }

      template <typename OutputConsumer, typename ErrorConsumer>
      inline int streamDiagnostics(Command<Memory>& command, Clock::time_point deadline, OutputConsumer&& output, ErrorConsumer&& error) {
        return execute(command, deadline, ExecutionOptions{}, output, error);
      }

      // Writes `input` to the command while both of its streams go to their consumers; `output`
      // returns false to stop reading, which ends the command.
      template <typename OutputConsumer, typename ErrorConsumer>
      inline int streamWithInput(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input, OutputConsumer&& output, ErrorConsumer&& error) {
        return execute(command, deadline, ExecutionOptions{.input = input}, output, error);
      }

      inline bool truncated() const noexcept {
        return truncated_;
      }

      inline std::string_view text() const noexcept {
        const auto bytes = output_.readable();

        return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
      }

    private:
      struct ExecutionOptions {
        std::span<const std::string_view> input{};
        const std::atomic<bool>* cancelled = nullptr;
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
      inline int execute(Command<Memory>& command, Clock::time_point deadline, ExecutionOptions options, Consumer&& consume, ErrorConsumer&& consume_error = nullptr) {
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

      inline static void writeInput(PipeProcess& process, std::span<const std::string_view>& input, std::size_t& offset) {
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

      inline void checkCancellation(const std::atomic<bool>* request_cancelled) const {
        if ((cancelled_ != nullptr && *cancelled_) || (request_cancelled != nullptr && *request_cancelled)) {
          throw RequestError{FailureCode::invalid_request, "Command cancelled"};
        }
      }

      ByteQueue<Memory> output_;
      std::size_t limit_;
      const std::atomic<bool>* cancelled_;
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

      // The first of `candidates`, each relative to this executable's directory, that is a regular
      // file this process may execute and whose directory entry carries exactly its name: APFS and
      // HFS+ match names case-insensitively, so `telar` would otherwise find a bundle's `Telar`.
      // The path found is resolved to the file itself.
      inline static std::optional<ExecutablePath> sibling(std::initializer_list<std::string_view> candidates) {
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

      inline const char* c_str() const noexcept {
        return path_.data();
      }

      inline std::string_view view() const noexcept {
        return path_.data();
      }

    private:
      inline static bool exactlyNamed(const char* path) noexcept {
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

      std::array<char, PATH_MAX> path_;
    };

  }
}

// Interface: telar_platform/login_shell.cppm
export {
  namespace telar::runtime {

    // The user's login shell: SHELL when the session names one, else the account's shell, else
    // /bin/sh. An empty account shell, or a path longer than PATH_MAX, counts as none.
    inline FixedText<PATH_MAX> loginShell() {
      FixedText<PATH_MAX> shell;
      const auto pick = [&](const char* candidate) {
        if (candidate == nullptr || *candidate == '\0' || std::strlen(candidate) > PATH_MAX) {
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

    // The line `shell -c` runs to exec the command its positional parameters name; empty for a
    // shell whose flags telar does not know. The runtime recognizes the panes it launched through a
    // login shell by this exact line.
    inline std::string_view loginShellScript(std::string_view shell) noexcept {
      const auto name = shell.substr(shell.rfind('/') + 1);
      if (name == "bash" || name == "zsh" || name == "ksh") {
        return "exec -- \"$0\" \"$@\"";
      }

      if (name == "sh" || name == "dash") {
        return "exec \"$0\" \"$@\"";
      }

      return name == "fish" ? "exec $argv" : std::string_view{};
    }

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
#if defined(__APPLE__)
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
        checkSpawn(posix_spawnattr_setflags(&attributes, flags | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK));
      }

      inline ~SpawnOptions() {
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attributes);
      }

      SpawnOptions(const SpawnOptions&) = delete;
      SpawnOptions& operator=(const SpawnOptions&) = delete;

      inline void redirect(int source, int destination) {
        checkSpawn(posix_spawn_file_actions_adddup2(&actions, source, destination));
      }

      inline void changeDirectory(const char* path) {
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

      posix_spawnattr_t attributes{};
      posix_spawn_file_actions_t actions{};
    };

  }
}
