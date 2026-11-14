export module telar.cli.server;

import std;

export import telar.cli.base.command_error;
import telar.cli.output;

export import telar.cli.runtime_observer;
export import telar.platform.daemon;
export import telar.platform.error;
export import telar.platform.paths;
export import telar.platform.process;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: help.cppm
export {
  namespace telar::runtime::cli {

    // What a `--help` asks about: the root when `family` is empty, a family when
    // `command` is empty, otherwise one command of the family.
    struct HelpTopic {
      std::string_view family;
      std::string_view command;
    };

    std::optional<std::string_view> helpText(HelpTopic topic) noexcept;

    // The help a command line asks for: a leading flag asks for
    // the root, and a flag anywhere after a family, but before `--`, for that family or
    // the command its second word names. Help never starts or contacts a runtime.
    std::optional<HelpTopic> findHelp(std::span<char* const> words) noexcept;

    // The words a usage error points at, as in "see `telar pane read --help`".
    std::string helpReference(std::span<char* const> words);

  }
}

// Interface: server.cppm
export {
  namespace telar::runtime::cli {

    inline constexpr const char* runtime_program = "telar-runtime";

    bool connectExisting(std::optional<RuntimeConnection>& connection, const char* path);

    enum class RuntimeStart : std::uint8_t {
      listening,
      exited,
      timed_out,
    };

    // Launches the sibling runtime where none listens and waits up to ten seconds
    // for its socket.
    template <Allocator Memory>
    RuntimeStart startRuntime(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths);
    extern template RuntimeStart startRuntime<Memory>(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths);

    // `telar server` runs the runtime in this process: the runtime executable installed
    // beside this one replaces it with the same arguments, so signals and exit status are its own.
    template <Allocator Memory>
    [[noreturn]] void execRuntime(Memory& memory, std::span<char* const> arguments);
    extern template void execRuntime<Memory>(Memory& memory, std::span<char* const> arguments);

    template <Allocator Memory>
    void runServer(Memory& memory, std::span<char* const> arguments);
    extern template void runServer<Memory>(Memory& memory, std::span<char* const> arguments);

  }
}
