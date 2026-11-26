module;
#include "tbc/annotations.hpp"

export module telar.platform.process;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;

import telar.platform.primitives;
import telar.vocabulary;
import telar.sys.posix;
import telar.sys.process;
import telar.base.ds;

// Interface: telar_platform/child_descriptors.cppm
export {
  namespace telar::runtime {

    // The descriptor a forked child keeps open past its standard streams, and the bound of the
    // descriptors it may hold.
    struct RetainedDescriptor {
      int retained;
      int limit;
    };

    void closeChildDescriptors(RetainedDescriptor kept) noexcept;

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
      PtyProcess(PtyProcess&&) = delete;
      PtyProcess& operator=(PtyProcess&&) = delete;

      [[nodiscard]] int descriptor() const noexcept;
      [[nodiscard]] pid_t processId() const noexcept;

      void resize(TerminalSize size);
      [[nodiscard]] ds::Option<pid_t> foregroundProcessGroup() const noexcept;
      void signal(int signal_number) const noexcept;
      void shutdown() const noexcept;
      ds::Option<int> reap() noexcept;

    private:
      FileDescriptor master_;
      pid_t process_id_ = -1;
      ds::Option<int> exit_status_;
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

    // What findExecutable looks for: `program` along `path`, a colon-separated directory list. A
    // relative directory, the empty one included, is relative to `cwd`, or to this process's
    // working directory when `cwd` is empty.
    struct ExecutableSearch {
      std::string_view path;
      std::string_view program;
      std::string_view cwd;
    };

    // Where exec finds the program `search` names: the first `directory/program` that is a file
    // this process may execute, written to `found` with its terminator. A candidate longer than PATH_MAX is passed
    // over.
    bool findExecutable(ExecutableSearch search, std::span<char, PATH_MAX> found) noexcept;

    enum class CommandPurpose : std::uint8_t {
      terminal,
      administration,
      configured_helper,
    };

    template <Allocator Memory>
    class Command {
    public:
      // Copies the launch; it keeps only its allocator, region `a`.
      explicit Command(tbc::mut_a<Memory> memory, const Launch& launch, CommandPurpose purpose = CommandPurpose::terminal);
      ~Command() = default;

      Command(const Command&) = delete;
      Command& operator=(const Command&) = delete;
      Command(Command&&) = delete;
      Command& operator=(Command&&) = delete;

      void removeEnvironmentPrefix(std::string_view prefix);
      [[nodiscard]] ds::Option<std::string_view> environment(std::string_view name) const noexcept;
      void removeEnvironment(std::string_view name);

      // The process starts with these after the program instead of the launch's own arguments,
      // which stay what the pane records and restores.
      void replaceSpawnArguments(std::span<const std::string_view> arguments);

      void setEnvironment(EnvironmentEntry variable);
      SpawnSpec specification(TerminalSize size);
      [[nodiscard]] std::string_view cwd() const noexcept;
      [[nodiscard]] std::span<const ds::String<Memory>> arguments() const noexcept;
      [[nodiscard]] bool restorable() const noexcept;

    private:
      static bool definesVariable(std::string_view entry, std::string_view name) noexcept;

      void resolveExecutable();

      using SensitiveMemory = ErasingAllocator<Memory>;
      tbc::val_a<ds::String<Memory>> executable_;
      tbc::val_a<ds::String<Memory>> cwd_;
      tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> arguments_;
      tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> spawn_arguments_;
      tbc::val_a<SensitiveMemory> environment_memory_;
      // The environment allocates from the sibling allocator, and the spawn arrays point into the
      // command's own strings, so a command keeps its address.
      tbc::val_self<ds::Vec<ds::String<SensitiveMemory>, SensitiveMemory>> environment_;
      tbc::val_self<ds::Vec<const char*, Memory>> argument_pointers_;
      tbc::val_self<ds::Vec<const char*, Memory>> environment_pointers_;
      tbc::mut_a<Memory> memory_;
      bool restorable_;
    };

    template <Allocator Memory>
    Command(Memory& memory, const Launch& launch, CommandPurpose purpose = CommandPurpose::terminal) -> Command<Memory>;

  }
}

// Interface: telar_platform/pipe_process.cppm
export {
  namespace telar::runtime {

    enum class ProcessInput : std::uint8_t {
      pipe,
      buffered_socket,
    };

    class PipeProcess {
    public:
      explicit PipeProcess(const SpawnSpec& specification, ProcessInput input = ProcessInput::pipe);
      ~PipeProcess();
      PipeProcess(const PipeProcess&) = delete;
      PipeProcess& operator=(const PipeProcess&) = delete;
      PipeProcess(PipeProcess&&) = delete;
      PipeProcess& operator=(PipeProcess&&) = delete;

      [[nodiscard]] int input() const noexcept;
      [[nodiscard]] int output() const noexcept;
      [[nodiscard]] int error() const noexcept;
      [[nodiscard]] pid_t processId() const noexcept;

      void closeInput() noexcept;
      void closeOutput() noexcept;
      void closeError() noexcept;

      void signal(int number) const noexcept;
      ds::Option<int> reap() noexcept;

    private:
      FileDescriptor input_;
      FileDescriptor output_;
      FileDescriptor error_;
      pid_t process_id_ = -1;
      ds::Option<int> exit_status_;
    };

  }
}

// Interface: telar_platform/command_output.cppm
export {
  namespace telar::runtime {

    // A consumer of the bytes a command writes, borrowed for the call that receives it. An output
    // consumer returns false to stop reading; what an error consumer returns is ignored.
    class BytesConsumer {
    public:
      template <typename Consumer>
        requires(!std::same_as<std::remove_cvref_t<Consumer>, BytesConsumer> && std::invocable<Consumer&, std::span<const Byte>>)
      TBC_GENERIC BytesConsumer(Consumer&& consumer) noexcept // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor): a call passes its lambda where it takes a BytesConsumer, as Rust passes a closure as `&mut dyn FnMut`
          : consumer_(erasedAddress(std::forward<Consumer>(consumer))),
            consume_([](void* target, std::span<const Byte> bytes) {
              auto& consume = *static_cast<std::remove_reference_t<Consumer>*>(target);

              if constexpr (std::is_void_v<std::invoke_result_t<Consumer&, std::span<const Byte>>>) {
                consume(bytes);
                return true;
              } else {
                return static_cast<bool>(consume(bytes));
              }
            }) {}

      bool operator()(std::span<const Byte> bytes) const;

    private:
      // The consumer's address with its type erased; the trampoline casts it back to the type, and
      // so the constness, the consumer came with.
      template <typename Object>
      TBC_GENERIC static void* erasedAddress(const Object& object) noexcept {
        return tbc::raw(const_cast<void*>(static_cast<const void*>(std::addressof(object)))); // NOLINT(cppcoreguidelines-pro-type-const-cast): the trampoline restores the consumer's own type and constness
      }

      void* consumer_;
      bool (*consume_)(void* consumer, std::span<const Byte> bytes);
    };

    template <Allocator Memory>
    class CommandOutput {
    public:
      using Clock = std::chrono::steady_clock;

      explicit CommandOutput(Memory& memory, std::size_t limit, const std::atomic<bool>* cancelled = nullptr);

      int run(Command<Memory>& command, Clock::time_point deadline, bool retain_prefix = false, const std::atomic<bool>* cancelled = nullptr);
      int runWithInput(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input);
      int runWithInputDiagnostics(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input, BytesConsumer error);
      int stream(Command<Memory>& command, Clock::time_point deadline, BytesConsumer consume);
      int streamDiagnostics(Command<Memory>& command, Clock::time_point deadline, BytesConsumer output, BytesConsumer error);

      // Writes `input` to the command while both of its streams go to their consumers; `output`
      // returns false to stop reading, which ends the command.
      int streamWithInput(Command<Memory>& command, Clock::time_point deadline, std::span<const std::string_view> input, BytesConsumer output, BytesConsumer error);

      [[nodiscard]] bool truncated() const noexcept;
      [[nodiscard]] std::string_view text() const noexcept;

    private:
      struct ExecutionOptions {
        std::span<const std::string_view> input;
        const std::atomic<bool>* cancelled = nullptr;
      };

      bool append(std::span<const Byte> bytes, bool retain_prefix);
      int execute(Command<Memory>& command, Clock::time_point deadline, ExecutionOptions options, BytesConsumer consume, const BytesConsumer* consume_error = nullptr);
      static void writeInput(PipeProcess& process, std::span<const std::string_view>& input, std::size_t& offset);
      void checkCancellation(const std::atomic<bool>* request_cancelled) const;

      ByteQueue<Memory> output_;
      std::size_t limit_;
      const std::atomic<bool>* cancelled_;
      bool truncated_ = false;
    };

  }
}

// Interface: telar_platform/executable_path.cppm
export {
  namespace telar::runtime {

    class ExecutablePath {
    public:
      ExecutablePath();

      // The executable called `name` beside this one, as installed telar programs are:
      // `telar` and `telar-runtime` share a directory, and symlinks resolve to it first.
      explicit ExecutablePath(std::string_view name);

      // The first of `candidates`, each relative to this executable's directory, that is a regular
      // file this process may execute and whose directory entry carries exactly its name: APFS and
      // HFS+ match names case-insensitively, so `telar` would otherwise find a bundle's `Telar`.
      // The path found is resolved to the file itself.
      static ds::Option<ExecutablePath> sibling(std::initializer_list<std::string_view> candidates);

      [[nodiscard]] const char* cStr() const noexcept;
      [[nodiscard]] std::string_view view() const noexcept;

    private:
      static bool exactlyNamed(const char* path) noexcept;

      ds::Array<char, PATH_MAX> path_{};
    };

  }
}

// Interface: telar_platform/login_shell.cppm
export {
  namespace telar::runtime {

    // The user's login shell: SHELL when the session names one, else the account's shell, else
    // /bin/sh. A relative or empty path, or one longer than PATH_MAX, counts as none: the runtime
    // would search its own PATH for a relative program, which need not be the user's.
    FixedText<PATH_MAX> loginShell();

    // The line `shell -c` runs to exec the command its positional parameters name; empty for a
    // shell whose flags telar does not know. The runtime recognizes the panes it launched through a
    // login shell by this exact line.
    std::string_view loginShellScript(std::string_view shell) noexcept;

  }
}

// Interface: telar_platform/spawn_options.cppm
export {
  namespace telar::runtime {

    void checkSpawn(int result);

    class SpawnOptions {
    public:
      explicit SpawnOptions(short flags);
      ~SpawnOptions();

      SpawnOptions(const SpawnOptions&) = delete;
      SpawnOptions& operator=(const SpawnOptions&) = delete;
      SpawnOptions(SpawnOptions&&) = delete;
      SpawnOptions& operator=(SpawnOptions&&) = delete;

      void redirect(int source, int destination);
      void changeDirectory(const char* path);

      // The child keeps only the standard streams and what `redirect` placed.
      // musl has no addclosefrom, so there every descriptor above stderr is
      // marked close-on-exec in this process instead: the child loses it at
      // exec, this process keeps it, and dup2 targets are fresh descriptors.
      void closeOthers();

      // The child keeps this process's standard streams, or what `redirect` placed on them, and
      // nothing else.
      void keepStandardStreams();

      posix_spawnattr_t attributes{};
      posix_spawn_file_actions_t actions{};
    };

  }
}

// The allocators the templates above are built for, in process.cpp: the erased Memory family and the
// stacks of base allocators that callers build directly. Any other allocator goes behind a
// MemoryAdapter.
namespace telar::runtime {

  extern template class Command<Memory>;
  extern template class Command<ConcurrentMemory>;
  extern template class Command<SystemAllocator>;
  extern template class Command<BudgetAllocator<SystemAllocator>>;
  extern template class Command<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  extern template class CommandOutput<Memory>;
  extern template class CommandOutput<ConcurrentMemory>;
  extern template class CommandOutput<SystemAllocator>;
  extern template class CommandOutput<BudgetAllocator<SystemAllocator>>;
  extern template class CommandOutput<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
