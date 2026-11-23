export module telar.cli.commands.project_setup;

import std;
import telar.tbc;

import telar.cli.console.command_limit;

import telar.cli.console.output;

import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.content;
import telar.wire.execution;
import telar.cli.commands.history;
import telar.cli.commands.plugin;
import telar.cli.session.runtime_observer;
import telar.cli.session.control_session;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: pane_agent_options.cppm
export {
  namespace telar::runtime::cli::pane_agents {

    inline constexpr std::uint32_t default_interval_ms = 250;
    inline constexpr std::uint32_t default_timeout_seconds = 30;
    inline constexpr std::uint16_t default_read_lines = 40;

    struct Options {
      std::string_view action;
      std::string_view target;
      std::string_view text;
      ds::Option<std::string_view> workspace;
      ds::Option<std::string_view> tab;
      tbc::val_a<const char*> socket = nullptr;
      bool json = false;
      bool stdin_text = false;
      bool enter = false;
      bool interrupt = false;
      bool wait = false;
      bool finished = false;
      AgentStatus until = AgentStatus::done;
      std::uint32_t timeout = default_timeout_seconds;
      std::uint16_t lines = default_read_lines;
      PaneTextSource source = PaneTextSource::recent;
      ds::Option<PaneDirection> direction;
      ds::Option<std::uint32_t> count;
      std::uint32_t interval = default_interval_ms;
      ReportAgent report{};
      ReportAgentCommand command{};
    };

    Options parsePane(std::span<char* const> words);

    Options parseAgent(std::span<char* const> words);

  }
}

// Interface: pane_agent_control.cppm
export {
  namespace telar::runtime::cli::pane_agents {

    void writeText(Output& out, const PaneText& reply, bool json, bool agent);

    tbc::val_a<AgentSnapshotEntry> resolve(tbc::ref_a<AgentSnapshot> snapshot, std::string_view target, ds::Option<std::uint64_t> worktree = ds::none);

  }
}

// Interface: agent.cppm
export {
  namespace telar::runtime::cli {

    int runAgent(Memory& memory, const pane_agents::Options& options);

  }
}

// Interface: execution_options.cppm
export {
  namespace telar::runtime::cli {

    struct ExecutionOptions {
      enum class Action : std::uint8_t {
        start,
        status,
        output,
        cancel,
        forget,
        list,
      };
      static constexpr std::size_t max_arguments = 64;
      Action action = Action::start;
      std::uint64_t id = 0;
      std::uint64_t workspace = 0;
      std::string_view cwd;
      std::string_view socket;
      ds::Array<std::string_view, max_arguments> arguments{};
      std::size_t argument_count = 0;
      bool detach = false;
      bool json = false;
      bool stdin_open = true;
      bool autoshare = false;
      std::uint32_t timeout_seconds = 0;
      std::uint64_t stdout_offset = 0;
      std::uint64_t stderr_offset = 0;

      static ExecutionOptions parse(Arguments words);
    };

  }
}

// Interface: execution.cppm
export {
  namespace telar::runtime::cli::execution {

    bool finished(const ExecutionReply& reply);

    tbc::val_a<ExecutionReply> exchange(tbc::mut_a<ControlSession> session, ExecutionRequest request);

    void list(ControlSession& session);

    int start(ControlSession& session, const ExecutionOptions& options);

    int run(Memory& memory, const ExecutionOptions& options);

  }
}

// Interface: pane.cppm
export {
  namespace telar::runtime::cli {

    int runPane(Memory& memory, const pane_agents::Options& options);

  }
}

// Interface: project_setup.cppm
export {
  namespace telar::runtime::cli::project_setup {

    struct Options {
      std::string_view cwd;
      bool detach = false;

      static Options parse(Arguments words);
    };

    // `project setup` and `worktree create --setup` share the authorization gate and execution semantics.
    tbc::val_a<ds::Option<std::uint64_t>> prepare(tbc::mut_a<Memory> memory, ControlSession& session, std::string_view cwd, bool authorized, bool detach = false);

    // Starts the runtime only when the checkout declares a recipe.
    tbc::val_a<ds::Option<std::uint64_t>> prepare(tbc::mut_a<Memory> memory, std::string_view cwd, bool authorized, bool detach, std::string_view socket);

    int run(Memory& memory, const Options& options);

  }
}
