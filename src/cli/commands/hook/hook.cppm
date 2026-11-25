export module telar.cli.commands.hook;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.cli.commands.hooks.command;
import telar.platform.paths;

import telar.cli.commands.hooks.session;

import telar.base.memory.allocators;
import telar.cli.commands.worktree_git;
import telar.base.ds;
import telar.base.memory.containers;
import telar.wire.agents;
import telar.wire.vocabulary;

// Interface: hooks/input.cppm
export {
  namespace telar::runtime::cli::hooks {

    class Input {
    public:
      static constexpr std::size_t maximum_bytes = std::size_t{16} * 1024 * 1024;

      explicit Input(Memory& memory);

      void read(int descriptor);

      [[nodiscard]] bool limited() const noexcept;

      [[nodiscard]] std::uint64_t received() const noexcept;

      [[nodiscard]] std::string_view text() const noexcept;

    private:
      void keepWholeMembers();

      ds::String<Memory> text_;
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
      std::string_view cursor(const Payload& input, const Environment& environment) noexcept;

    private:
      template <EnvironmentLookup Environment>
      ds::Option<std::string_view> cursorRoot(const Environment& environment);

      ds::Option<std::string_view> cursorChat(std::string_view root, std::string_view chat);

      ds::Option<std::string_view> cursorPath(std::string_view root, std::string_view digest, std::string_view chat);

      static tbc::val_a<ds::Option<std::string_view>> copy(std::string_view value, tbc::val_a<std::span<char>> buffer) noexcept;

      static tbc::val_a<ds::Option<std::string_view>> join(std::string_view root, std::string_view suffix, tbc::val_a<std::span<char>> buffer) noexcept;

      ds::Array<char, PATH_MAX> root_{};
      ds::Array<char, PATH_MAX> path_{};
    };

  }
}

// Not exported. map and runHook, templates its importers name, reach these, so they keep
// module linkage: an internal one would be exposed to the importers
// (-Wreference-tu-local-entity-in-other-tu). Helpers that only these call stay internal in hook.cpp.
namespace telar::runtime::cli::hooks {

  tbc::val_a<ds::Option<ReportAgent>> claudeLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event);

  tbc::val_a<ds::Option<ReportAgent>> codexLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event, tbc::val_a<std::string_view> database);

  tbc::val_a<ds::Option<ReportAgent>> piLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event);

  tbc::val_a<ds::Option<ReportAgent>> openCodeLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event);

  tbc::val_a<ds::Option<ReportAgent>> antigravityLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event);

  tbc::val_a<ds::Option<ReportAgent>> cursorLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event, tbc::val_a<std::string_view> metadata);

  tbc::val_a<ds::Option<ReportAgentProgress>> progressReport(tbc::ref_a<Payload> input, tbc::mut_a<ReportTexts> texts);

  tbc::val_a<ds::Option<ReportAgentTitle>> titleReport(const Payload& input, tbc::mut_a<FixedText<display_line_bytes>> text);

  ds::Option<std::uint64_t> unsignedValue(std::string_view value) noexcept;

  bool validWorktreeBranch(std::string_view branch) noexcept;

  template <EnvironmentLookup Environment>
  ds::Option<PaneTarget> paneTarget(const Environment& environment, AgentProvider provider) noexcept;

  template <EnvironmentLookup Environment>
  class Worktrees;

  template <EnvironmentLookup Environment>
  ds::Option<int> answerWorktree(Memory& memory, const Environment& environment, Object& fields, std::string_view socket);

  // Sends the runtime what the hook's payload reported.
  void sendReports(Session& session, const Reports& reports, const Input& input);

}

// Interface: hooks/map.cppm
export {
  namespace telar::runtime::cli::hooks {

    template <EnvironmentLookup Environment>
    // The reports view the payload, the files and their own texts, all region `a`.
    void map(tbc::mut_a<Payload> input, tbc::mut_a<Reports> reports, tbc::mut_a<ReportTexts> texts, tbc::mut_a<SessionFiles> files, const Environment& environment);
    extern template void map<ProcessEnvironment>(tbc::mut_a<Payload> input, tbc::mut_a<Reports> reports, tbc::mut_a<ReportTexts> texts, tbc::mut_a<SessionFiles> files, const ProcessEnvironment& environment);

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
