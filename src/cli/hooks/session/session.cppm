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

      std::size_t countExcept(std::string_view finished) const noexcept;

    private:
      static tbc::view<std::string_view, tbc::lt::a> value(tbc::view<std::string_view, tbc::lt::a> item, std::string_view key) noexcept;

      std::size_t find(std::string_view identifier) const noexcept;

      void apply(std::string_view item) noexcept;

      std::size_t scan(std::string_view bytes, bool at_end) noexcept;

      ds::Array<FixedText<64>, 32> identifiers_;
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
      FixedText<96> event;
      FixedText<96> step;
      FixedText<96> title_text;
      FixedText<2048> message;
      LinkedWorktree worktree;
    };

    struct Reports {
      ds::Option<ReportAgent> lifecycle;
      ds::Option<ReportAgentCommand> command;
      ds::Option<ReportAgentTitle> title;
      ds::Option<ReportAgentProgress> progress;

      bool empty() const noexcept;
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
        } catch (const std::exception&) {
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
