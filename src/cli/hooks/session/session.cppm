module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.cli.hooks.session;

import std;
import telar.tbc;

import telar.cli.control_session;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.runtime;
import telar.git.checkout;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: hooks/codex_subagents.cppm
export {
  namespace telar::runtime::cli::hooks {

    class CodexSubagents {
    public:
      void read(std::string_view path) noexcept;

      [[nodiscard]] std::size_t countExcept(std::string_view finished) const noexcept;

    private:
      // A thread identifier's bytes, and how many running subagents the hook follows.
      static constexpr std::size_t identifier_bytes = 64;
      static constexpr std::size_t maximum_subagents = 32;

      static tbc::val_a<std::string_view> value(tbc::val_a<std::string_view> item, std::string_view key) noexcept;

      [[nodiscard]] std::size_t find(std::string_view identifier) const noexcept;

      void apply(std::string_view item) noexcept;

      std::size_t scan(std::string_view bytes, bool at_end) noexcept;

      ds::Array<FixedText<identifier_bytes>, maximum_subagents> identifiers_;
      std::size_t count_ = 0;
    };

  }
}

// Interface: hooks/reports.cppm
export {
  namespace telar::runtime::cli::hooks {

    // The text the reports show, apart from them: a report views these and the payload, as a Rust
    // `Reports<'a>` borrows the buffers it does not own.
    struct ReportTexts {
      // The runtime's bounds of a display line and of a message, as hooks' display_line_bytes and
      // display_message_bytes, which the functions that write these texts take.
      static constexpr std::size_t line_bytes = 96;
      static constexpr std::size_t message_bytes = 2048;

      FixedText<line_bytes> event;
      FixedText<line_bytes> step;
      FixedText<line_bytes> title_text;
      FixedText<message_bytes> message;
      LinkedWorktree worktree;
    };

    struct Reports {
      ds::Option<ReportAgent> lifecycle;
      ds::Option<ReportAgentCommand> command;
      ds::Option<ReportAgentTitle> title;
      ds::Option<ReportAgentProgress> progress;

      [[nodiscard]] bool empty() const noexcept;
    };

  }
}

// Interface: hooks/session.cppm
export {
  namespace telar::runtime::cli::hooks {

    struct PaneTarget {
      std::uint64_t pane_id;
      std::uint64_t generation;
      AgentProvider provider;
    };

    // The hook's conversation with the runtime: every report carries the pane and
    // provider the hook runs for, and the runtime first verifies the reporter's ancestry.
    class Session {
    public:
      Session(Memory& memory, const char* socket, PaneTarget target);

      // The members generic over the protocol's messages keep their bodies here,
      // marked TBC_GENERIC: the messages are an open set that no implementation
      // unit can instantiate ahead.
      template <typename Report>
      TBC_GENERIC inline void report(Report value) noexcept {
        try {
          TELAR_TRACE("hooks.sendReport");
          exchange(value);
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a report is best effort; the hook never fails the agent over one.
        }
      }

      void reportLimit(std::uint64_t received, std::size_t capacity) noexcept;

      template <typename Reply = RequestCompleted, typename Report>
      TBC_GENERIC inline Reply exchange(Report value) {
        if constexpr (requires { value.pane_id; value.pane_generation; }) {
          value.pane_id = target_.pane_id;
          value.pane_generation = target_.generation;
        }

        if constexpr (requires { value.provider = AgentProvider{}; }) {
          value.provider = target_.provider;
        }

        return control_.template exchange<Reply>(value);
      }

    private:
      static constexpr std::size_t reply_bytes = 2048;

      ControlSession control_;
      PaneTarget target_;
    };

  }
}
