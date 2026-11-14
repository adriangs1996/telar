export module telar.cli.hook;

import std;
import telar.sys.posix;
import telar.tbc;

export import telar.cli.hooks.command;
export import telar.platform.paths;
import telar.platform.process;

export import telar.cli.hooks.session;

export import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.cli.worktree_git;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.layout;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.git.checkout;
import telar.platform.primitives;
import telar.base.text;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.platform.error;
import telar.platform.fs;

// Interface: hooks/input.cppm
export {
  namespace telar::runtime::cli::hooks {

    class Input {
    public:
      static constexpr std::size_t maximum_bytes = 16 * 1024 * 1024;

      explicit Input(Memory& memory);

      void read(int descriptor);

      bool limited() const noexcept;

      std::uint64_t received() const noexcept;

      std::string_view text() const noexcept;

    private:
      void keepWholeMembers();

      bool completeMember(std::size_t start, std::size_t end, String<Memory>& candidate);

      String<Memory> text_;
      std::uint64_t received_ = 0;
    };

  }
}

// Interface: hooks/session_files.cppm
export {
  namespace telar::runtime::cli::hooks {

    class SessionFiles {
    public:
      template <EnvironmentLookup Environment>
      std::string_view codex(const Environment& environment) noexcept;

      template <EnvironmentLookup Environment>
      std::string_view cursor(Payload& input, const Environment& environment) noexcept;

    private:
      template <EnvironmentLookup Environment>
      std::optional<std::string_view> cursorRoot(const Environment& environment);

      std::optional<std::string_view> cursorPath(std::string_view root, std::string_view digest, std::string_view chat);

      static tbc::view<std::optional<std::string_view>, tbc::lt::a> copy(std::string_view value, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept;

      static tbc::view<std::optional<std::string_view>, tbc::lt::a> join(std::string_view root, std::string_view suffix, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept;

      std::array<char, PATH_MAX> root_;
      std::array<char, PATH_MAX> path_;
    };

  }
}

// Interface: hooks/map.cppm
export {
  namespace telar::runtime::cli::hooks {

    template <EnvironmentLookup Environment>
    // The reports view the payload, the files and their own texts, all region `a`.
    void map(tbc::view<Payload&, tbc::lt::a> input, tbc::view<Reports&, tbc::lt::a> reports, tbc::view<SessionFiles&, tbc::lt::a> files, const Environment& environment);
    extern template void map<ProcessEnvironment>(tbc::view<Payload&, tbc::lt::a> input, tbc::view<Reports&, tbc::lt::a> reports, tbc::view<SessionFiles&, tbc::lt::a> files, const ProcessEnvironment& environment);

  }
}

// Interface: hook.cppm
export {
  namespace telar::runtime::cli {

    template <EnvironmentLookup Environment>
    int runHook(Memory& memory, const HookOptions& options, const Environment& environment) noexcept;
    extern template int runHook<ProcessEnvironment>(Memory& memory, const HookOptions& options, const ProcessEnvironment& environment) noexcept;

  }
}
