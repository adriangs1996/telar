module;

export module telar.cli.server;

import std;

import telar.cli.output;

import telar.platform.paths;
import telar.cli.control_session;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: help.cppm
export {
  namespace telar::runtime::cli {

    // The version `telar --version`, the root help and machine setup report.
    inline constexpr std::string_view version{
#include "version.inc"
    };

    // What a `--help` asks about: the root when `family` is empty, a family when
    // `command` is empty, otherwise one command of the family.
    struct HelpTopic {
      std::string_view family;
      std::string_view command;
    };

    ds::Option<std::string_view> helpText(HelpTopic topic) noexcept;

    // The help a command line asks for: a leading flag asks for
    // the root, and a flag anywhere after a family, but before `--`, for that family or
    // the command its second word names. Help never starts or contacts a runtime.
    ds::Option<HelpTopic> findHelp(std::span<char* const> words) noexcept;

    // The words a usage error points at, as in "see `telar pane read --help`".
    // The help to read after an argument error, as `telar FAMILY COMMAND --help`.
    ErrorText<127> helpReference(std::span<char* const> words);

  }
}

// Interface: server.cppm
export {
  namespace telar::runtime::cli {

    inline constexpr const char* runtime_program = "telar-runtime";

    bool connectExisting(ds::Option<RuntimeConnection>& connection, const char* path);

    enum class RuntimeStart : std::uint8_t {
      listening,
      exited,
      timed_out,
    };

    // Launches the sibling runtime where none listens and waits up to ten seconds
    // for its socket.
    RuntimeStart startRuntime(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths);

    // `telar server` runs the runtime in this process: the runtime executable installed
    // beside this one replaces it with the same arguments, so signals and exit status are its own.
    [[noreturn]] void execRuntime(Memory& memory, std::span<char* const> arguments);

    void runServer(Memory& memory, std::span<char* const> arguments);

  }
}
