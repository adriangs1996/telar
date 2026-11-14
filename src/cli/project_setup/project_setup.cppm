module;
#include "tbc/view.hpp"

export module telar.cli.project_setup;

import std;

export import telar.cli.command_limit;

export import telar.cli.output;

import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.content;
import telar.wire.execution;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.base.text;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.cli.history;
import telar.cli.plugin;
import telar.cli.runtime_observer;
import telar.cli.server;
import telar.cli.control_session;

// Interface: pane_agent_options.cppm
export {
  namespace telar::runtime::cli::pane_agents {

    inline constexpr std::uint32_t default_interval_ms = 250;

    struct Options {
      std::string_view action{};
      std::string_view target{};
      std::string_view text{};
      std::optional<std::string_view> workspace{};
      std::optional<std::string_view> tab{};
      tbc::view<const char*, tbc::lt::a> socket = nullptr;
      bool json = false;
      bool stdin_text = false;
      bool enter = false;
      bool interrupt = false;
      bool wait = false;
      bool finished = false;
      AgentStatus until = AgentStatus::done;
      std::uint32_t timeout = 30;
      std::uint16_t lines = 40;
      PaneTextSource source = PaneTextSource::recent;
      std::optional<PaneDirection> direction{};
      std::optional<std::uint32_t> count{};
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

    template <Allocator Memory>
    void writeText(Output<Memory>& out, const PaneText& reply, bool json, bool agent);

    tbc::view<AgentSnapshotEntry, tbc::lt::a> resolve(tbc::view<const AgentSnapshot&, tbc::lt::a> snapshot, std::string_view target, std::optional<std::uint64_t> worktree = std::nullopt);

  }
}

// Interface: agent.cppm
export {
  namespace telar::runtime::cli {

    template <Allocator Memory>
    int runAgent(Memory& memory, const pane_agents::Options& options);
    extern template int runAgent<Memory>(Memory& memory, const pane_agents::Options& options);

  }
}

// Interface: execution_options.cppm
export {
  namespace telar::runtime::cli {

    struct ExecutionOptions {
      enum class Action {
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
      std::array<std::string_view, max_arguments> arguments{};
      std::size_t argument_count = 0;
      bool detach = false;
      bool json = false;
      bool stdin_open = true;
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

    template <Allocator Memory>
    tbc::view<ExecutionReply, tbc::lt::a> exchange(tbc::view<ControlSession<Memory>&, tbc::lt::a> session, ExecutionRequest request);

    template <Allocator Memory>
    void list(ControlSession<Memory>& session);

    template <Allocator Memory>
    int start(ControlSession<Memory>& session, const ExecutionOptions& options);

    template <Allocator Memory>
    int run(Memory& memory, const ExecutionOptions& options);
    extern template int run<Memory>(Memory& memory, const ExecutionOptions& options);

  }
}

// Interface: pane.cppm
export {
  namespace telar::runtime::cli {

    template <Allocator Memory>
    int runPane(Memory& memory, const pane_agents::Options& options);
    extern template int runPane<Memory>(Memory& memory, const pane_agents::Options& options);

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
    template <Allocator Memory>
    std::optional<std::uint64_t> prepare(Memory& memory, ControlSession<Memory>& session, std::string_view cwd, bool authorized, bool detach = false);
    extern template std::optional<std::uint64_t> prepare<Memory>(Memory& memory, ControlSession<Memory>& session, std::string_view cwd, bool authorized, bool detach);

    // Starts the runtime only when the checkout declares a recipe.
    template <Allocator Memory>
    std::optional<std::uint64_t> prepare(Memory& memory, std::string_view cwd, bool authorized, bool detach, std::string_view socket);

    template <Allocator Memory>
    int run(Memory& memory, const Options& options);
    extern template int run<Memory>(Memory& memory, const Options& options);

  }
}
