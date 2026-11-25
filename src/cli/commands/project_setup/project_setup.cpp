module telar.cli.commands.project_setup;

import telar.tbc;
import telar.cli.console.command_error;
import telar.cli.session.control_session;
import telar.platform.error;
import telar.platform.sha256;
import telar.sys.posix;
import telar.platform.paths;
import telar.base.text.utf8;
import telar.cli.session.server;
import telar.platform.primitives;
import telar.platform.process;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.base.ds;
import telar.base.memory.containers;
import telar.base.text;
import telar.base.text.json;

namespace telar::runtime::cli {

  namespace {

    // How long a command waits for each reply of the runtime.
    constexpr unsigned reply_timeout_seconds = 30;

  }

}

namespace telar::runtime::cli::pane_agents {

  constexpr std::size_t max_input_bytes = 65536;
  constexpr std::uint16_t max_read_rows = 2000;
  constexpr std::uint32_t max_timeout_seconds = 86400;
  constexpr std::uint32_t min_interval_ms = 10;
  constexpr std::uint32_t max_interval_ms = 60000;
  // The status an agent command that timed out ends with.
  constexpr int timed_out_status = 3;

  constexpr ds::Array<std::string_view, 11> report_states{"working", "blocked", "ready", "exited", "settling", "continuing", "waiting", "idle", "released", "failed", "interrupted"};
  constexpr ds::Array<std::string_view, 3> session_file_kinds{"claude_transcript", "codex_state", "cursor_meta"};

  namespace {

    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_character = 0x7f;
    constexpr std::size_t max_search_bytes = 128;
    constexpr std::string_view worktree_prefix = "worktree:";

    // The bytes an agent's reports may carry.
    constexpr std::size_t max_title_bytes = 96;
    constexpr std::size_t max_session_reference_bytes = 64;
    constexpr std::size_t max_session_file_bytes = 1024;
    constexpr std::size_t max_event_bytes = 96;
    constexpr std::size_t max_provider_bytes = 64;
    constexpr std::size_t max_tool_call_bytes = 256;
    constexpr std::size_t max_cwd_bytes = 4096;

    bool displayText(std::string_view text) {
      return inspectUtf8(text) == Utf8Validation::valid && std::ranges::none_of(text, [](unsigned char byte) {
        return byte < first_printable || byte == delete_character;
      });
    }

    void socketOption(tbc::mut_a<Options> options, Cursor& cursor) {
      const auto value = cursor.take("MissingSocketPath");

      if (options.socket != nullptr) {
        usage("DuplicateSocketOption");
      }

      options.socket = value.data();
    }

    void readOption(Options& options, Cursor& cursor, std::string_view option) {
      if (option == "--lines") {
        options.lines = number<std::uint16_t>(cursor.take("MissingLineCount"), "InvalidLineCount");
        if (options.lines == 0 || options.lines > max_read_rows) {
          usage("InvalidLineCount");
        }
      } else {
        const auto source = cursor.take("MissingTextSource");
        if (source != "screen" && source != "recent") {
          usage("InvalidTextSource");
        }

        options.source = source == "screen" ? PaneTextSource::screen : PaneTextSource::recent;
      }
    }

    bool knownPaneAction(std::string_view action) noexcept {
      constexpr ds::Array<std::string_view, 8> actions{"read", "send-keys", "focus", "theme", "list", "get", "watch", "search"};

      return std::ranges::find(actions, action) != actions.end();
    }

    // A pane by its id, the current one, or the agent's of a worktree.
    bool validPaneTarget(std::string_view target) noexcept {
      return target == "--current" || maybeUnsigned(target) || (target.starts_with(worktree_prefix) && target.size() > worktree_prefix.size());
    }

    // The text `search` and `send-keys` take after the target.
    void paneText(tbc::mut_a<Options> options, Cursor& cursor) {
      const auto action = options.action;

      options.text = cursor.take(action == "search" ? "MissingSearchText" : "MissingSendText");
      options.stdin_text = action == "send-keys" && options.text == "--stdin";
      if (action == "search") {
        if (options.text.empty() || options.text.size() > max_search_bytes || inspectUtf8(options.text) != Utf8Validation::valid) {
          usage("InvalidSearchText");
        }
      } else if (!options.stdin_text && (options.text.empty() || options.text.size() > max_input_bytes)) {
        usage("send-keys needs text of 1 to 65536 bytes, or --stdin");
      }
    }

    // `--workspace` or `--tab`, which `arg` names.
    void paneScopeOption(tbc::mut_a<Options> options, Cursor& cursor, std::string_view arg) {
      const bool workspace = arg == "--workspace";
      auto& target = workspace ? options.workspace : options.tab;
      if (target) {
        usage(workspace ? "DuplicateWorkspaceOption" : "DuplicateTabOption");
      }

      target = cursor.take(workspace ? "MissingWorkspaceId" : "MissingTabId");
      if (*target != "--current") {
        positive(*target, "InvalidIdentity");
      }
    }

    // `--count` and `--interval-ms` of `pane watch`.
    void watchOption(Options& options, Cursor& cursor, std::string_view arg) {
      if (arg == "--count") {
        options.count = number<std::uint32_t>(cursor.take("MissingCount"), "InvalidCount");
        if (*options.count == 0) {
          usage("InvalidCount");
        }

        return;
      }

      options.interval = number<std::uint32_t>(cursor.take("MissingInterval"), "InvalidInterval");
      if (options.interval < min_interval_ms || options.interval > max_interval_ms) {
        usage("InvalidInterval");
      }
    }

    // An option of a pane command; false where `arg` is none of its action's.
    bool paneOption(tbc::mut_a<Options> options, Cursor& cursor, std::string_view arg) {
      const auto action = options.action;
      const bool listing = action == "list" || action == "get" || action == "watch";

      if (arg == "--json" || (arg == "--jsonl" && action == "watch")) {
        options.json = true;
      } else if (arg == "--socket") {
        socketOption(options, cursor);
      } else if ((arg == "--workspace" || arg == "--tab") && listing) {
        paneScopeOption(options, cursor, arg);
      } else if (arg == "--enter" && action == "send-keys") {
        options.enter = true;
      } else if ((arg == "--lines" || arg == "--source") && (action == "read" || action == "watch")) {
        readOption(options, cursor, arg);
      } else if (action == "watch" && ((arg == "--count" && !options.count) || arg == "--interval-ms")) {
        watchOption(options, cursor, arg);
      } else if (arg == "--direction" && action == "focus" && !cursor.empty() && !options.direction) {
        options.direction = choice<PaneDirection>(cursor.take("UnknownPaneOption"), "InvalidPaneDirection", pane_directions);
      } else {
        return false;
      }

      return true;
    }

    // The text the agent action takes after its target.
    void agentText(tbc::mut_a<Options> options, Cursor& cursor) {
      const auto action = options.action;
      if (action == "report-command") {
        constexpr ds::Array<std::string_view, 2> phases{"started", "finished"};
        const auto phase = cursor.take("MissingCommandReport");

        options.command.command = cursor.take("MissingCommandReport");
        options.command.phase = choice<AgentCommandPhase>(phase, "InvalidCommandPhase", phases);
      } else if (action == "report-state") {
        options.report.state = choice<AgentReportState>(cursor.take("MissingAgentState"), "InvalidAgentState", report_states);
      } else if (action == "report-title") {
        options.text = cursor.take("MissingAgentTitle");
        if (!options.text.empty() && (options.text.size() > max_title_bytes || !displayText(options.text))) {
          usage("InvalidSessionTitle");
        }
      } else if (action == "report-session") {
        options.text = cursor.take("MissingSessionReference");
        if (options.text.empty() || options.text.size() > max_session_reference_bytes) {
          usage("InvalidSessionReference");
        }
      } else if (action == "prompt") {
        options.text = cursor.take("MissingPromptText");
        if (options.text.size() > max_input_bytes) {
          usage("InvalidPromptText");
        }
      }
    }

    // An option of `agent report-command`; false where `arg` is none of them.
    bool commandReportOption(tbc::mut_a<ReportAgentCommand> command, Cursor& cursor, std::string_view arg) {
      if (arg == "--provider") {
        command.provider = cursor.take("MissingProvider");
      } else if (arg == "--tool-call") {
        command.tool_call_id = cursor.take("MissingToolCall");
      } else if (arg == "--cwd") {
        command.cwd = cursor.take("MissingCwd");
      } else if (arg == "--session") {
        command.session = cursor.take("MissingSessionReference");
      } else if (arg == "--exit-code") {
        command.exit_code = signedNumber<std::int32_t>(cursor.take("MissingExitCode"), "InvalidExitCode");
      } else {
        return false;
      }

      return true;
    }

    // An option of `agent report-state`; false where `arg` is none of them.
    bool stateReportOption(tbc::mut_a<ReportAgent> report, Cursor& cursor, std::string_view arg) {
      if (arg == "--blocked-reason") {
        const auto reason = agentBlockedReasonNamed(cursor.take("MissingBlockedReason"));
        if (!reason) {
          usage("InvalidBlockedReason");
        }

        report.blocked_reason = *reason;
      } else if (arg == "--event") {
        report.event = cursor.take("MissingAgentEvent");
      } else if (arg == "--session") {
        report.session = cursor.take("MissingSessionReference");
      } else if (arg == "--session-file") {
        report.session_file = cursor.take("MissingSessionFile");
      } else if (arg == "--session-file-kind") {
        report.session_file_kind = choice<AgentSessionFileKind>(cursor.take("MissingSessionFileKind"), "InvalidSessionFileKind", session_file_kinds);
      } else {
        return false;
      }

      return true;
    }

    // `--until STATUS` of `agent wait`, where idle names ready.
    void waitUntil(Options& options, std::string_view status) {
      options.finished = status == "finished";
      if (options.finished) {
        return;
      }

      options.until = agentStatusNamed(status == "idle" ? std::string_view{"ready"} : status).valueOr(AgentStatus::unknown);
      if (options.until == AgentStatus::unknown) {
        usage("InvalidWaitStatus");
      }
    }

    // `--timeout SECONDS`, which may end in `s`.
    void agentTimeout(Options& options, std::string_view text) {
      while (text.ends_with('s')) {
        text.remove_suffix(1);
      }

      options.timeout = number<std::uint32_t>(text, "InvalidTimeout");
      if (options.timeout == 0 || options.timeout > max_timeout_seconds) {
        usage("InvalidTimeout");
      }
    }

    // An option of an agent command; false where `arg` is none of its action's.
    bool agentOption(tbc::mut_a<Options> options, Cursor& cursor, std::string_view arg) {
      const auto action = options.action;

      if (arg == "--json") {
        options.json = true;
      } else if (arg == "--socket") {
        socketOption(options, cursor);
      } else if (action == "report-command") {
        return commandReportOption(options.command, cursor, arg);
      } else if (action == "report-state") {
        return stateReportOption(options.report, cursor, arg);
      } else if (arg == "--interrupt" && action == "prompt") {
        options.interrupt = true;
      } else if (arg == "--wait" && action == "prompt") {
        options.wait = true;
      } else if (arg == "--until" && action == "wait") {
        waitUntil(options, cursor.take("MissingWaitStatus"));
      } else if (arg == "--timeout" && (action == "wait" || action == "prompt")) {
        agentTimeout(options, cursor.take("MissingTimeout"));
      } else if ((arg == "--lines" || arg == "--source") && action == "read") {
        readOption(options, cursor, arg);
      } else {
        return false;
      }

      return true;
    }

  }

  Options parsePane(std::span<char* const> words) {
    Cursor cursor{words};
    Options options{.action = cursor.take("MissingPaneAction")};
    const auto action = options.action;
    if (!knownPaneAction(action)) {
      usage("UnknownPaneAction");
    }

    if (action != "list") {
      options.target = cursor.take("MissingPaneTarget");
      if (!validPaneTarget(options.target)) {
        usage("InvalidPaneId");
      }
    }

    if ((action == "focus" || action == "theme") && options.target != "--current") {
      usage(action == "focus" ? "FocusRequiresCurrentPane" : "ThemeRequiresCurrentPane");
    }

    if (action == "search" || action == "send-keys") {
      paneText(options, cursor);
    }

    while (const auto word = cursor.next()) {
      if (!paneOption(options, cursor, *word)) {
        usage("UnknownPaneOption");
      }
    }

    if (action == "focus" && !options.direction) {
      usage("MissingPaneDirection");
    }

    if (options.tab && !options.workspace) {
      usage("TabRequiresWorkspace");
    }

    return options;
  }

  Options parseAgent(std::span<char* const> words) {
    Cursor cursor{words};
    Options options{.action = cursor.take("MissingAgentAction")};
    const auto action = options.action;
    constexpr ds::Array<std::string_view, 11> actions{"list", "get", "wait", "prompt", "read", "interrupt", "acknowledge", "report-session", "report-title", "report-state", "report-command"};
    if (std::ranges::find(actions, action) == actions.end()) {
      usage("UnknownAgentAction");
    }

    if (action != "list") {
      options.target = cursor.take("MissingAgentTarget");
    }

    agentText(options, cursor);
    while (const auto word = cursor.next()) {
      if (!agentOption(options, cursor, *word)) {
        usage("UnknownAgentOption");
      }
    }

    if (action == "prompt" && options.text.empty()) {
      usage("InvalidPromptText");
    }

    if (action == "report-command" && (options.command.provider.empty() || options.command.command.empty() || (options.command.phase == AgentCommandPhase::started && options.command.exit_code))) {
      usage("InvalidCommandReport");
    }

    return options;
  }

  constexpr auto poll_interval = std::chrono::milliseconds{250};
  constexpr auto submit_delay = std::chrono::milliseconds{150};
  constexpr auto start_grace = std::chrono::seconds{5};
  constexpr auto interrupt_settle = std::chrono::seconds{15};

  namespace {

    std::uint64_t current(const char* name, bool nonzero = false) {
      const auto text = process_environment.lookup(name);
      const auto id = maybeUnsigned(text);
      if (!id || (nonzero && *id == 0)) {
        throw Failure{missing_pane_context};
      }

      return *id;
    }

    std::uint64_t paneId(std::string_view target) {
      if (target == "--current") {
        return current("TELAR_PANE_ID");
      }

      if (const auto id = maybeUnsigned(target)) {
        return *id;
      }

      throw Failure{"InvalidPaneId"};
    }

    std::uint64_t entityId(std::string_view target, const char* variable) {
      if (target == "--current") {
        const auto value = process_environment.lookup(variable);
        if (value.empty()) {
          throw Failure{"MissingCurrentIdentity"};
        }

        try {
          return positive(value, "InvalidIdentity");
        } catch (const std::invalid_argument&) {
          throw Failure{"InvalidIdentity"};
        }
      }

      return positive(target, "InvalidIdentity");
    }

    void validateBytes(std::string_view value, std::size_t maximum, bool empty = true) {
      if (value.size() > maximum || (!empty && value.empty())) {
        throw Failure{"InvalidByteString"};
      }

      if (value.contains('\0')) {
        throw Failure{"EmbeddedNul"};
      }
    }

    void validateSession(std::string_view value) {
      try {
        validateAgentSession(value, false);
      } catch (const EncodingError&) {
        throw Failure{"InvalidSessionReference"};
      }
    }

    void validateReport(const Options& options) {
      if (options.action == "report-state") {
        const auto& report = options.report;
        if (!report.session.empty()) {
          validateSession(report.session);
        }

        validateBytes(report.session_file, max_session_file_bytes);
        validateBytes(report.event, max_event_bytes);
        if (inspectUtf8(report.event) != Utf8Validation::valid) {
          throw Failure{"InvalidUtf8"};
        }

        if (!displayText(report.event)) {
          throw Failure{"InvalidAgentDisplayText"};
        }

        if (report.state != AgentReportState::blocked && report.blocked_reason != AgentBlockedReason::none) {
          throw Failure{"InvalidAgentBlockedReason"};
        }
      } else if (options.action == "report-command") {
        const auto& command = options.command;

        validateBytes(command.provider, max_provider_bytes, false);
        validateBytes(command.tool_call_id, max_tool_call_bytes);
        validateBytes(command.command, max_input_bytes, false);
        validateBytes(command.cwd, max_cwd_bytes);
        if (!command.session.empty()) {
          validateSession(command.session);
        }
      }
    }

    bool equalTitle(std::string_view left, std::string_view right) {
      return asciiEqualIgnoreCase(left, right);
    }

    ServerOptions socketOptions(const char* socket) {
      ServerOptions options;

      options.socket = (socket != nullptr) ? socket : "";
      return options;
    }

    // Attaches to the runtime (start false) or opens it, starting it when none
    // listens; a connection failure ends the command with `error: NAME`.
    template <Allocator Memory>
    void connectRuntime(Memory& memory, const RuntimePaths<Memory>& paths, bool start) {
      try {
        const RuntimeConnection probe{paths.socket.data()};

        return;
      } catch (const SystemError& error) {
        if (!start || (error.code() != ENOENT && error.code() != ECONNREFUSED)) {
          throw CommandError{sys::errorName(error.code())};
        }
      }

      if (startRuntime(memory, ServerOptions(), paths) != RuntimeStart::listening) {
        throw CommandError{"RuntimeUnavailable"};
      }
    }

    void writeAgent(Output& out, const AgentSnapshotEntry& agent, bool json) {
      const auto provider = agent.provider_name.empty() ? std::string_view{"unknown"} : agent.provider_name;
      const auto status = agentStatusName(agent.status);

      if (json) {
        out.text("{\"pane_id\":").number(agent.pane_id).text(",\"pane_generation\":").number(agent.pane_generation).text(",\"workspace_id\":").number(agent.location.workspace.id).text(",\"tab_id\":").number(agent.location.tab_id).text(",\"pane_index\":").number(agent.pane_index).text(",\"provider\":").json(provider, JsonEscapes::control).text(",\"provider_index\":").number(static_cast<unsigned>(agent.provider)).text(",\"status\":").json(status, JsonEscapes::control);
        out.text(",\"workspace\":").json(agent.workspace_label, JsonEscapes::control).text(",\"tab\":").json(agent.tab_label, JsonEscapes::control).text(",\"title\":").json(agent.session_title, JsonEscapes::control).text(",\"cwd\":").json(agent.cwd_label, JsonEscapes::control).text(",\"blocked_reason\":").json(agentBlockedReasonName(agent.blocked_reason), JsonEscapes::control).text(",\"status_age_s\":").number(agent.status_age_s).text(",\"worktree_id\":").number(agent.work_tree).text(",\"last_event\":").json(agent.last_event, JsonEscapes::control);
        out.text(R"(,"plan":{"done":)").number(agent.plan_done).text(",\"total\":").number(agent.plan_total).text(",\"step\":").json(agent.plan_step, JsonEscapes::control).text("},\"final_message\":").json(agent.final_message, JsonEscapes::control).text(R"(,"session_id":")");
        ds::Array<char, 2 * sizeof(agent.session_id)> session{};

        out.text(encodeLowerHex(agent.session_id, session.viewMut()));

        out.text("\"}");
        return;
      }

      const auto column = [&](std::string_view text, std::size_t width) {
        out.text(text);
        if (text.size() < width) {
          out.data.resize(out.data.size() + width - text.size(), ' ');
        }
      };

      const auto numeric = [&](std::uint64_t value, std::size_t width) {
        const auto start = out.data.size();

        out.number(value);
        const auto used = out.data.size() - start;
        if (used < width) {
          out.data.resize(out.data.size() + width - used, ' ');
        }
      };

      // The widths of agent_header's columns.
      constexpr std::size_t pane_width = 6;
      constexpr std::size_t generation_width = 5;
      constexpr std::size_t status_width = 9;
      // "antigravity", the longest built-in name, and the gap after it.
      constexpr std::size_t provider_width = 13;
      constexpr std::size_t workspace_width = 18;
      constexpr std::size_t tab_width = 14;

      numeric(agent.pane_id, pane_width);
      numeric(agent.pane_generation, generation_width);
      column(status, status_width);
      column(provider, provider_width);
      column(agent.workspace_label, workspace_width);
      column(agent.tab_label, tab_width);
      out.text(agent.session_title).text("\n");
    }

    constexpr std::string_view agent_header = "PANE  GEN  STATUS   PROV         WORKSPACE         TAB           TITLE\n";

    void writeOne(Output& out, const AgentSnapshotEntry& agent, bool json) {
      if (!json) {
        out.text(agent_header);
      }

      writeAgent(out, agent, json);
      if (json) {
        out.text("\n");
      }
    }

  }

  void writeText(Output& out, const PaneText& reply, bool json, bool agent) {
    if (json) {
      out.text("{\"pane_id\":").number(reply.pane_id).text(",\"truncated\":").boolean(reply.truncated).text(",\"exit_code\":");
      if (reply.exit_code) {
        out.number(*reply.exit_code);
      } else {
        out.text("null");
      }

      out.text(",\"text\":").json(reply.text, JsonEscapes::control).text("}\n");
      return;
    }

    out.text(reply.text);
    if (!reply.text.empty() && !reply.text.ends_with('\n')) {
      out.text("\n");
    }

    if (reply.truncated) {
      writeFormatted(STDERR_FILENO, "telar {}: older rows were omitted\n", agent ? "agent" : "pane");
    }

    if (!agent && reply.exit_code) {
      writeFormatted(STDERR_FILENO, "telar pane: the command exited with {}\n", *reply.exit_code);
    }
  }

  namespace {

    struct PaneRecord {
      TabLocation location;
      std::uint16_t position;
      PaneDescriptor pane;
    };

    WorkspaceList runtimeList(ControlSession& session) {
      session.send(RequestRuntimeState{.client_identity = static_cast<std::uint64_t>(::getpid()), .interactive = false});
      return session.template receive<WorkspaceList>();
    }

    template <Allocator Memory>
    tbc::val_a<ds::Vec<PaneRecord, Memory>> paneCatalog(tbc::mut_a<Memory> memory, const char* socket, const Options& options) {
      ControlSession session{memory, socket};

      session.receiveTimeout(reply_timeout_seconds);
      ds::Vec<std::uint64_t, Memory> workspaces{memory};
      ds::Vec<PaneRecord, Memory> records{memory};

      if (options.workspace) {
        workspaces.push(entityId(*options.workspace, "TELAR_WORKSPACE_ID"));
      } else {
        for (const auto& entry : runtimeList(session).entries) {
          workspaces.push(entry.workspace);
        }
      }

      for (const auto workspace : workspaces) {
        ds::Vec<std::uint64_t, Memory> tabs{memory};
        const WorkspaceLocation location{.id = workspace};

        if (options.tab) {
          tabs.push(entityId(*options.tab, "TELAR_TAB_ID"));
        } else {
          const auto snapshot = session.template exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.workspace = location});
          if (snapshot.workspace.kind != location.kind || snapshot.workspace.id != workspace) {
            throw Failure{"unexpected reply from the runtime"};
          }

          for (const auto& entry : snapshot.tabs) {
            tabs.push(entry.tab_id);
          }
        }

        for (const auto tab : tabs) {
          const TabLocation target{.workspace = location, .tab_id = tab};
          const auto snapshot = session.template exchange<TabSnapshot>(RequestTabSnapshot{.location = target});
          if (snapshot.location.workspace.kind != target.workspace.kind || snapshot.location.workspace.id != workspace || snapshot.location.tab_id != tab) {
            throw Failure{"unexpected reply from the runtime"};
          }

          std::uint16_t position = 0;

          for (const auto pane : snapshot.panes) {
            records.push(PaneRecord{.location = target, .position = position++, .pane = pane});
          }
        }
      }

      return records;
    }

    // The one worktree whose branch (or, without `branch`, title) is `reference`, if any.
    ds::Option<std::uint64_t> matchingWorktree(const WorkspaceList& list, std::string_view reference, bool branch) {
      ds::Option<std::uint64_t> found;

      for (const auto& tree : list.worktrees) {
        if (branch ? tree.branch == reference : equalTitle(tree.title, reference)) {
          if (found) {
            throw Failure{"more than one worktree has that branch or title; name it by the other"};
          }

          found = tree.worktree;
        }
      }

      return found;
    }

    template <Allocator Memory>
    std::uint64_t worktreeId(Memory& memory, const char* socket, std::string_view reference) {
      ControlSession session{memory, socket};

      session.receiveTimeout(reply_timeout_seconds);
      const auto list = runtimeList(session);

      for (const bool branch : {true, false}) {
        if (const auto found = matchingWorktree(list, reference, branch)) {
          return *found;
        }
      }

      throw Failure{"no tracked worktree matches that branch or title", 2};
    }

    // What names an agent: its worktree, else its pane, else its session's title.
    struct AgentTarget {
      std::string_view title;
      ds::Option<std::uint64_t> pane;
      ds::Option<std::uint64_t> worktree;
    };

    bool matches(const AgentSnapshotEntry& entry, const AgentTarget& target) {
      if (target.worktree) {
        return entry.work_tree == *target.worktree;
      }

      if (target.pane) {
        return entry.pane_id == *target.pane;
      }

      return equalTitle(entry.session_title, target.title);
    }

    // The pane and generation that name a pane across the exchanges that reuse a snapshot's storage.
    struct PaneHandle {
      std::uint64_t pane_id;
      std::uint64_t pane_generation;
    };

  }

  tbc::val_a<AgentSnapshotEntry> resolve(tbc::ref_a<AgentSnapshot> snapshot, std::string_view target, ds::Option<std::uint64_t> worktree) {
    const AgentTarget wanted{
        .title = target,
        .pane = target == "--current" ? ds::Option{current("TELAR_PANE_ID")} : maybeUnsigned(target),
        .worktree = worktree,
    };

    ds::Option<AgentSnapshotEntry> found;

    for (const auto& entry : snapshot.entries) {
      if (matches(entry, wanted)) {
        if (found) {
          throw Failure{"more than one agent has that title; use the pane id"};
        }

        found = entry;
      }
    }

    if (!found) {
      throw Failure{worktree ? "no agent runs in that worktree" : "no agent matches that target", 2};
    }

    return *found;
  }

  namespace {

    ds::Option<std::uint64_t> senderPane(const Options& options, std::uint64_t target) {
      const ProcessEnvironment environment;
      const auto id = maybeUnsigned(environment.lookup("TELAR_PANE_ID"));
      // A later lookup may overwrite the storage an earlier one returned.
      const auto socket_path = environment.lookup("TELAR_SOCKET_PATH");
      FixedText<PATH_MAX> own;

      if (!id || *id == target || socket_path.empty() || socket_path.size() > PATH_MAX) {
        return ds::none;
      }

      own.assign(socket_path);

      const auto socket = (options.socket != nullptr) ? std::string_view{options.socket} : environment.lookup("TELAR_SOCKET");
      if (!socket.empty() && socket != own.view()) {
        return ds::none;
      }

      if (*id == 0) {
        throw Failure{"InvalidPaneId"};
      }

      return *id;
    }

    // The pane by its ids: an entry of a snapshot views the session's storage, which the exchange reuses.
    void interruptAgent(ControlSession& session, std::uint64_t pane, std::uint64_t generation) {
      session.template exchange<RequestCompleted>(InterruptAgent{.pane_id = pane, .pane_generation = generation});
    }

    int waitAgent(ControlSession& session, const Options& options, ds::Option<std::uint64_t> worktree, Output& out) {
      const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds{options.timeout};

      for (;;) {
        const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
        const auto agent = resolve(snapshot, options.target, worktree);
        if (options.finished ? agent.status == AgentStatus::done || agent.status == AgentStatus::ready : agent.status == options.until) {
          writeOne(out, agent, options.json);
          return 0;
        }

        if (std::chrono::system_clock::now() >= deadline) {
          writeFormatted(STDERR_FILENO, "telar agent: timed out after {}s; agent is {}\n", options.timeout, agentStatusName(agent.status));
          return timed_out_status;
        }

        std::this_thread::sleep_for(poll_interval);
      }
    }

    void settleAgent(ControlSession& session, std::uint64_t pane, std::uint64_t generation) {
      interruptAgent(session, pane, generation);
      const auto deadline = std::chrono::system_clock::now() + interrupt_settle;

      while (std::chrono::system_clock::now() < deadline) {
        std::this_thread::sleep_for(poll_interval);
        const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
        const auto found = std::ranges::find(snapshot.entries, pane, &AgentSnapshotEntry::pane_id);
        if (found == snapshot.entries.end()) {
          throw Failure{"no agent matches that target", 2};
        }

        if (found->status != AgentStatus::working) {
          return;
        }
      }

      throw Failure{"InterruptNotSettled"};
    }

    // Waits until the prompted agent starts working and settles, blocks or fails.
    int awaitPrompt(ControlSession& session, const Options& options, PaneHandle pane, Output& out) {
      const auto start_deadline = std::chrono::system_clock::now() + start_grace;
      const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds{options.timeout};
      bool started = false;

      for (;;) {
        const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
        const auto found = std::ranges::find(snapshot.entries, pane.pane_id, &AgentSnapshotEntry::pane_id);
        if (found == snapshot.entries.end() || found->pane_generation != pane.pane_generation) {
          throw Failure{"no agent matches that target", 2};
        }

        const auto& agent = *found;
        if (agent.status == AgentStatus::working) {
          started = true;
        } else if (started || agent.status == AgentStatus::blocked || agent.status == AgentStatus::failed) {
          writeOne(out, agent, options.json);
          return agent.status == AgentStatus::failed ? 1 : 0;
        } else if (std::chrono::system_clock::now() >= start_deadline) {
          writeFormatted(STDERR_FILENO, "telar agent: the agent did not start working within 5s\n");
          return timed_out_status;
        }

        if (std::chrono::system_clock::now() >= deadline) {
          writeFormatted(STDERR_FILENO, "telar agent: timed out after {}s; agent is still working\n", options.timeout);
          return timed_out_status;
        }

        std::this_thread::sleep_for(poll_interval);
      }
    }

    int promptAgent(ControlSession& session, const Options& options, PaneHandle pane, AgentStatus status, Output& out) {
      if (options.interrupt && status == AgentStatus::working) {
        settleAgent(session, pane.pane_id, pane.pane_generation);
      }

      session.template exchange<RequestCompleted>(SendPaneText{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .mode = PaneTextMode::prompt, .text = options.text, .sender = senderPane(options, pane.pane_id)});
      if (!options.wait) {
        return 0;
      }

      return awaitPrompt(session, options, pane, out);
    }

    void reportAgent(ControlSession& session, const Options& options, const std::pair<std::uint64_t, std::uint64_t>& pane, Output& out) {
      try {
        session.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = pane.first, .pane_generation = pane.second});
      } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): the runtime checks the reporter's descent where it can; a report it cannot check still stands
      }

      validateReport(options);
      const auto report = [&](auto message) {
        message.pane_id = pane.first;
        message.pane_generation = pane.second;
        session.template exchange<RequestCompleted>(message);
      };

      if (options.action == "report-state") {
        report(options.report);
      } else if (options.action == "report-command") {
        report(options.command);
      } else {
        report(ReportAgentTitle{.title = options.text});
      }

      if (options.json) {
        out.text("{\"pane_id\":").number(pane.first).text(",\"pane_generation\":").number(pane.second).text(",\"accepted\":true}\n");
      }
    }

    void writeAgentList(Output& out, const AgentSnapshot& snapshot, bool json) {
      if (json) {
        out.text("{\"revision\":").number(snapshot.revision).text(",\"agents\":[");
      } else {
        out.text(agent_header);
      }

      bool first = true;

      for (const auto& agent : snapshot.entries) {
        if (json && !first) {
          out.text(",");
        }

        writeAgent(out, agent, json);
        first = false;
      }

      if (json) {
        out.text("]}\n");
      }
    }

    void acknowledgeAgent(ControlSession& session, PaneHandle pane, bool json, Output& out) {
      session.send(AcknowledgeAgent{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation});
      const auto updated = session.template exchange<AgentSnapshot>(QueryAgents{});
      const auto found = std::ranges::find(updated.entries, pane.pane_id, &AgentSnapshotEntry::pane_id);
      if (found == updated.entries.end() || found->pane_generation != pane.pane_generation) {
        throw Failure{"no agent matches that target", 2};
      }

      if (found->status == AgentStatus::done) {
        throw Failure{"AgentAcknowledgementNotApplied"};
      }

      writeOne(out, *found, json);
    }

    bool reportAction(std::string_view action) noexcept {
      return action == "report-title" || action == "report-state" || action == "report-command";
    }

    bool worktreeTarget(std::string_view target) noexcept {
      return target.starts_with(worktree_prefix) && target.size() > worktree_prefix.size();
    }

    // The worktree a `worktree:` target names. A report only checks the runtime answers its catalog.
    ds::Option<std::uint64_t> targetWorktree(Memory& memory, const RuntimePaths<Memory>& paths, const Options& options) {
      if (!worktreeTarget(options.target)) {
        return ds::none;
      }

      if (!reportAction(options.action)) {
        return worktreeId(memory, paths.socket.data(), options.target.substr(worktree_prefix.size()));
      }

      ControlSession catalog{memory, paths.socket.data()};

      catalog.receiveTimeout(reply_timeout_seconds);
      runtimeList(catalog);
      return ds::none;
    }

    // Runs an action on the one agent the target resolved to.
    void actOnAgent(Memory& memory, ControlSession& session, const Options& options, const AgentSnapshotEntry& agent, Output& out) {
      if (reportAction(options.action)) {
        reportAgent(session, options, {agent.pane_id, agent.pane_generation}, out);
      } else if (options.action == "get") {
        writeOne(out, agent, options.json);
      } else if (options.action == "read") {
        const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .rows = options.lines, .source = options.source});

        writeText(out, reply, options.json, true);
      } else if (options.action == "interrupt") {
        Output saved{memory};

        writeOne(saved, agent, options.json);
        interruptAgent(session, agent.pane_id, agent.pane_generation);
        out.text(saved.data);
      } else if (options.action == "acknowledge") {
        acknowledgeAgent(session, {.pane_id = agent.pane_id, .pane_generation = agent.pane_generation}, options.json, out);
      } else if (options.action == "report-session") {
        validateSession(options.text);
        session.template exchange<RequestCompleted>(ReportAgentSession{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .session = options.text});
      }
    }

    int executeAgent(Memory& memory, const RuntimePaths<Memory>& paths, const Options& options, Output& out) {
      ControlSession session{memory, paths.socket.data()};

      session.receiveTimeout(reply_timeout_seconds);
      const bool report = reportAction(options.action);
      const auto tree = targetWorktree(memory, paths, options);

      if (report && options.target == "--current") {
        reportAgent(session, options, {current("TELAR_PANE_ID"), current("TELAR_PANE_GENERATION", true)}, out);
        return 0;
      }

      const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});

      if (options.action == "list") {
        writeAgentList(out, snapshot, options.json);
        return 0;
      }

      // Manual reports resolve the agent snapshot without a worktree catalog.
      if (report && worktreeTarget(options.target)) {
        throw Failure{"WorktreeCatalogMissing"};
      }

      if (options.action == "wait") {
        return waitAgent(session, options, tree, out);
      }

      if (options.action == "prompt") {
        const auto refreshed = session.template exchange<AgentSnapshot>(QueryAgents{});
        const auto again = resolve(refreshed, options.target, tree);

        return promptAgent(session, options, {.pane_id = again.pane_id, .pane_generation = again.pane_generation}, again.status, out);
      }

      actOnAgent(memory, session, options, resolve(snapshot, options.target, tree), out);
      return 0;
    }

  }

}

namespace telar::runtime::cli {

  int runAgent(Memory& memory, const pane_agents::Options& options) {
    using namespace pane_agents;
    const RuntimePaths<Memory> paths{memory, socketOptions(options.socket), process_environment};

    connectRuntime(memory, paths, options.action != "acknowledge" && options.action != "report-title" && options.action != "report-state" && options.action != "report-command");
    Output out{memory};

    try {
      const auto result = executeAgent(memory, paths, options, out);

      out.flush();
      return result;
    } catch (const std::exception& error) {
      out.flush();
      return commandFailure("telar agent", error);
    }
  }

}

namespace telar::runtime::cli::execution {

  constexpr int failure_status = 125;
  constexpr int timeout_status = 124;
  constexpr std::chrono::milliseconds poll_interval{10};
  constexpr std::size_t max_chunk = 4096;

  namespace {

    std::string_view stateName(ExecutionState state) {
      constexpr ds::Array names{"starting", "running", "exited", "failed"};

      return names.at(static_cast<std::size_t>(state));
    }

  }

  bool finished(const ExecutionReply& reply) {
    return reply.state == ExecutionState::exited || reply.state == ExecutionState::failed;
  }

  tbc::val_a<ExecutionReply> exchange(tbc::mut_a<ControlSession> session, ExecutionRequest request) {
    for (;;) {
      try {
        return session.template exchange<ExecutionReply>(request);
      } catch (const ControlFailure& error) {
        if (error.message() != "ExecutionBusy") {
          throw;
        }

        std::this_thread::sleep_for(poll_interval);
      }
    }
  }

  namespace {

    void writeStatusJson(const ExecutionReply& reply) {
      writeFormatted(STDOUT_FILENO, "{{\"execution_id\":{},\"workspace_id\":{},\"state\":{},\"exit_code\":{},\"stdout_offset\":{},\"stderr_offset\":{},\"stdout_bytes\":{},\"stderr_bytes\":{},\"stdin_bytes\":{},\"stdin_open\":{},\"failure\":{}}}\n", reply.execution_id, reply.workspace_id, quoteJson(stateName(reply.state)), orNull(finished(reply) ? ds::Option{reply.exit_code} : ds::none), reply.stdout_offset, reply.stderr_offset, reply.stdout_total, reply.stderr_total, reply.input_offset, jsonBoolean(reply.stdin_open), quoteJson(textBytes(reply.failure)));
    }

    void writeStreams(ExecutionRequest& request, const ExecutionReply& reply) {
      if (request.stdout_offset != reply.stdout_offset || request.stderr_offset != reply.stderr_offset) {
        writeFormatted(STDERR_FILENO, "telar exec: retained output lost; resume with --stdout-offset {} --stderr-offset {}\n", reply.stdout_offset, reply.stderr_offset);
        throw std::runtime_error{"ExecutionOutputLost"};
      }

      writeBytes(STDOUT_FILENO, reply.stdout_bytes);
      writeBytes(STDERR_FILENO, reply.stderr_bytes);
      request.stdout_offset += reply.stdout_bytes.size();
      request.stderr_offset += reply.stderr_bytes.size();
    }

  }

  void list(ControlSession& session) {
    ExecutionRequest request{.action = ExecutionAction::list};
    DescriptorWriter output{STDOUT_FILENO};

    output.print("[");

    for (;;) {
      const auto reply = exchange(session, request);
      if (reply.execution_id == 0) {
        break;
      }

      if (request.execution_id != 0) {
        output.print(",");
      }

      output.print(R"({{"execution_id":{},"workspace_id":{},"state":{},"exit_code":{}}})", reply.execution_id, reply.workspace_id, quoteJson(stateName(reply.state)), orNull(finished(reply) ? ds::Option{reply.exit_code} : ds::none));
      request.execution_id = reply.execution_id;
    }

    output.print("]\n");
    output.flush();
  }

  namespace {

    // Forgets a finished execution; a refusal leaves it retained, as before.
    void release(ControlSession& session, ExecutionRequest request) noexcept {
      request.action = ExecutionAction::forget;
      try {
        exchange(session, request);
      } catch (...) { // NOLINT(bugprone-empty-catch): a refusal leaves the execution retained, which `exec forget` still clears
      }
    }

    // The status `exec` ends with once the execution finished and all its output reached this
    // process; none while it runs.
    ds::Option<int> finishedStatus(const ExecutionRequest& request, const ExecutionReply& reply) {
      if (!finished(reply) || request.stdout_offset != reply.stdout_total || request.stderr_offset != reply.stderr_total) {
        return ds::none;
      }

      constexpr int highest_status = 255;

      if (reply.state == ExecutionState::failed) {
        writeFormatted(STDERR_FILENO, "telar exec: {}\n", textBytes(reply.failure));
      }

      return std::clamp(reply.exit_code, 0, highest_status);
    }

    // Reads what stdin holds now into `bytes`: none when it holds nothing yet, 0 at its end.
    ds::Option<std::size_t> readyInput(std::span<Byte> bytes) {
      pollfd input{.fd = STDIN_FILENO, .events = POLLIN, .revents = 0};
      if (::poll(&input, 1, 0) <= 0) {
        return ds::none;
      }

      const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
      if (count < 0) {
        throw std::runtime_error{"ExecutionStdinFailed"};
      }

      return static_cast<std::size_t>(count);
    }

    // The request that follows an execution after the one that started or named it.
    void followWith(ExecutionRequest& request) noexcept {
      request.action = ExecutionAction::status;
      request.arguments = {};
      request.cwd = {};
    }

    // `exec output`: the output retained when it was asked for. Each reply views the session's
    // storage, so it is asked for here, where the next exchange replaces it.
    int followOutput(ControlSession& session, ExecutionRequest request) {
      auto reply = exchange(session, request);
      const auto stdout_end = reply.stdout_total;
      const auto stderr_end = reply.stderr_total;

      followWith(request);
      for (;;) {
        writeStreams(request, reply);
        if (request.stdout_offset >= stdout_end && request.stderr_offset >= stderr_end) {
          return 0;
        }

        reply = exchange(session, request);
      }
    }

    // Sends the request and follows the execution it starts or names until it ends. Each reply
    // views the session's storage, so it is asked for here, where the next exchange replaces it.
    int followExecution(ControlSession& session, ExecutionRequest request, const ExecutionOptions& options) {
      auto reply = exchange(session, request);
      const auto started = std::chrono::steady_clock::now();
      bool stdin_open = request.stdin_open;

      followWith(request);
      for (;;) {
        writeStreams(request, reply);
        if (const auto status = finishedStatus(request, reply)) {
          // The whole result reached this process: keeping it would only fill
          // the runtime's bounded table. A status equal to telar's own 124/125
          // stays, so `exec status` can still tell them apart. `reply` views
          // the session buffer, so the exchange comes after its last read.
          if (options.action == ExecutionOptions::Action::start && *status != timeout_status && *status != failure_status) {
            release(session, request);
          }

          return *status;
        }

        if (options.timeout_seconds != 0 && std::chrono::steady_clock::now() - started >= std::chrono::seconds{options.timeout_seconds}) {
          writeFormatted(STDERR_FILENO, "telar exec: wait timed out; execution {} continues\n", request.execution_id);
          return timeout_status;
        }

        if (stdin_open && reply.stdin_open && reply.input_available >= max_chunk) {
          ds::Array<Byte, max_chunk> bytes; // NOLINT(cppcoreguidelines-pro-type-member-init): read() fills what the chunk then sends, so a 4 KiB clear per chunk of stdin is waste
          if (const auto count = readyInput(bytes.viewMut())) {
            auto chunk = request;

            chunk.action = *count == 0 ? ExecutionAction::eof : ExecutionAction::input;
            chunk.bytes = bytes.view().first(*count);
            chunk.input_offset = reply.input_offset;
            reply = exchange(session, chunk);
            stdin_open = *count != 0;
            continue;
          }
        }

        if (reply.stdout_bytes.empty() && reply.stderr_bytes.empty()) {
          std::this_thread::sleep_for(poll_interval);
        }

        reply = exchange(session, request);
      }
    }

    int observe(ControlSession& session, const ExecutionRequest& request, const ExecutionOptions& options) {
      if (options.action == ExecutionOptions::Action::output) {
        return followOutput(session, request);
      }

      return followExecution(session, request, options);
    }

    // The request each option's action sends first.
    ExecutionAction requestAction(ExecutionOptions::Action action) noexcept {
      switch (action) {
      case ExecutionOptions::Action::start:
        return ExecutionAction::start;
      case ExecutionOptions::Action::cancel:
        return ExecutionAction::cancel;
      case ExecutionOptions::Action::forget:
        return ExecutionAction::forget;
      case ExecutionOptions::Action::status:
      case ExecutionOptions::Action::output:
      case ExecutionOptions::Action::list:
        return ExecutionAction::status;
      }

      return ExecutionAction::status;
    }

  }

  int start(ControlSession& session, const ExecutionOptions& options) {
    if (options.action == ExecutionOptions::Action::list) {
      list(session);
      return 0;
    }

    ExecutionRequest request{
        .action = requestAction(options.action),
        .execution_id = options.id == 0 ? randomIdentity() : options.id,
        .workspace_id = options.workspace,
        .stdout_offset = options.stdout_offset,
        .stderr_offset = options.stderr_offset,
        .stdin_open = options.stdin_open && !options.detach,
        .cwd = options.cwd,
        .arguments = std::span{options.arguments}.first(options.argument_count),
    };

    try {
      if (options.action == ExecutionOptions::Action::status || options.action == ExecutionOptions::Action::cancel || options.action == ExecutionOptions::Action::forget || options.detach) {
        writeStatusJson(exchange(session, request));
        return 0;
      }

      return observe(session, request, options);
    } catch (...) {
      if (options.action == ExecutionOptions::Action::start) {
        writeFormatted(STDERR_FILENO, "telar exec: query execution {} before retrying an uncertain launch\n", request.execution_id);
      }

      throw;
    }
  }

  int run(Memory& memory, const ExecutionOptions& options) {
    try {
      ServerOptions server_options{};

      server_options.socket = options.socket;
      const RuntimePaths<Memory> paths{memory, server_options, process_environment};

      ensureRuntime(memory, paths);
      ControlSession session{memory, paths.socket.data()};

      session.receiveTimeout(reply_timeout_seconds);
      return start(session, options);
    } catch (const ControlFailure& error) {
      writeFormatted(STDERR_FILENO, "telar exec: {}\n", error.message().empty() ? std::string_view{error.what()} : error.message());
    } catch (const std::exception& error) {
      writeFormatted(STDERR_FILENO, "telar exec: {}\n", commandErrorName(error));
    }

    return failure_status;
  }

}

namespace telar::runtime::cli::pane_agents {

  constexpr ds::Array<std::string_view, 3> focus_outcomes{"focused", "no_neighbor", "source_not_focused"};
  constexpr ds::Array<std::string_view, 2> lifecycles{"running", "exited"};

  namespace {

    void writePane(Output& out, const PaneRecord& entry, bool json) {
      const auto& pane = entry.pane;
      const auto lifecycle = lifecycles.at(static_cast<std::size_t>(pane.lifecycle));

      if (json) {
        out.text("{\"workspace_id\":").number(entry.location.workspace.id).text(",\"tab_id\":").number(entry.location.tab_id).text(",\"position\":").number(entry.position).text(",\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"lifecycle\":").json(lifecycle, JsonEscapes::standard).text("}");
      } else {
        out.number(entry.location.workspace.id).text("\t").number(entry.location.tab_id).text("\t").number(pane.pane_id).text("\t").number(pane.pane_generation).text("\t").text(lifecycle).text("\n");
      }
    }

    // The record of the pane `wanted`, which the catalog must hold.
    const PaneRecord& cataloged(std::span<const PaneRecord> catalog, std::uint64_t wanted) {
      const auto found = std::ranges::find(catalog, wanted, [](const PaneRecord& entry) {
        return entry.pane.pane_id;
      });
      if (found == catalog.end()) {
        throw Failure{controlFailureDescription(FailureCode::pane_not_found), 2};
      }

      return *found;
    }

    void inspectPanes(Memory& memory, const char* socket, const Options& options, Output& out) {
      const auto catalog = paneCatalog(memory, socket, options);

      if (options.action == "get") {
        writePane(out, cataloged(catalog.view(), paneId(options.target)), options.json);
        if (options.json) {
          out.text("\n");
        }

        return;
      }

      out.text(options.json ? "[" : "WORKSPACE\tTAB\tPANE\tGENERATION\tLIFECYCLE\n");
      bool first = true;

      for (const auto& entry : catalog) {
        if (options.json && !first) {
          out.text(",");
        }

        writePane(out, entry, options.json);
        first = false;
      }

      if (options.json) {
        out.text("]\n");
      }
    }

    void watchPane(ControlSession& session, const Options& options, const PaneDescriptor& pane, Output& out) {
      ds::Option<ds::Array<std::uint8_t, SHA256_DIGEST_LENGTH>> previous;
      bool previous_truncated = false;
      std::uint64_t count = 0;

      for (;;) {
        const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .rows = options.lines, .source = options.source});
        if (reply.pane_id != pane.pane_id) {
          throw Failure{"unexpected reply from the runtime"};
        }

        Sha256 hash;

        hash.update(reply.text);
        const auto digest = hash.finish();
        if (!previous || digest != *previous || reply.truncated != previous_truncated) {
          out.text("{\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"truncated\":").boolean(reply.truncated).text(",\"text\":").json(reply.text, JsonEscapes::standard).text("}\n");
          out.flush();
          previous = digest;
          previous_truncated = reply.truncated;
          ++count;
          if (options.count && count >= *options.count) {
            return;
          }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds{options.interval});
      }
    }

    // `bytes` as "#rrggbb", or null when absent.
    void writeColor(Output& out, std::span<const Byte> bytes) {
      constexpr std::string_view digits = "0123456789abcdef";
      constexpr std::size_t quoted_color_bytes = 9;
      constexpr unsigned nibble_bits = 4;
      constexpr unsigned low_nibble = 0x0fU;
      ds::Array<char, quoted_color_bytes> text{'"', '#'};

      for (std::size_t index = 0; index < 3; ++index) {
        const unsigned byte = bytes[index];

        text.atMut(2 + (index * 2)) = digits[byte >> nibble_bits];
        text.atMut(3 + (index * 2)) = digits[byte & low_nibble];
      }

      text.atMut(text.size() - 1) = '"';
      out.text({text.data(), text.size()});
    }

    template <std::size_t Size>
    void writeOptionalColor(Output& out, const ds::Option<ds::Array<Byte, Size>>& bytes) {
      if (bytes) {
        writeColor(out, bytes->view());
      } else {
        out.text("null");
      }
    }

    // The theme as JSON: the terminal's colors, the 16 ANSI colors in `ansi`, each syntax role's
    // color and style, and each chrome role's color, by the names telar's themes give them.
    void writeTheme(Output& out, const TerminalTheme& theme) {
      out.text("{\"foreground\":");
      writeOptionalColor(out, theme.foreground);
      out.text(",\"background\":");
      writeOptionalColor(out, theme.background);
      out.text(",\"cursor\":");
      writeOptionalColor(out, theme.cursor);
      out.text(",\"ansi\":");
      if (theme.palette) {
        for (std::size_t index = 0; index < theme.palette->size() / 3; ++index) {
          out.text(index == 0 ? "[" : ",");
          writeColor(out, theme.palette->view().subspan(index * 3, 3));
        }

        out.text("]");
      } else {
        out.text("null");
      }

      out.text(",\"syntax\":");
      if (theme.syntax) {
        for (std::size_t index = 0; index < TerminalTheme::syntax_roles; ++index) {
          const auto bit = 1U << index;

          out.text(index == 0 ? "{" : ",").json(TerminalTheme::syntax_names[index]).text(":{\"color\":");
          writeColor(out, theme.syntax->view().subspan(index * 3, 3));
          out.text(",\"italic\":").boolean((theme.syntax_italic & bit) != 0).text(",\"bold\":").boolean((theme.syntax_bold & bit) != 0).text("}");
        }

        out.text("}");
      } else {
        out.text("null");
      }

      out.text(",\"chrome\":");
      if (theme.chrome) {
        for (std::size_t index = 0; index < TerminalTheme::chrome_roles; ++index) {
          out.text(index == 0 ? "{" : ",").json(TerminalTheme::chrome_names[index]).text(":");
          writeColor(out, theme.chrome->view().subspan(index * 3, 3));
        }

        out.text("}");
      } else {
        out.text("null");
      }

      out.text("}\n");
    }

    // Reads stdin to its end into `buffer`, as fread does; a failed read ends it.
    std::size_t readInput(std::span<char> buffer) {
      std::size_t total = 0;

      while (total < buffer.size()) {
        const auto rest = buffer.subspan(total);
        const auto count = ::read(STDIN_FILENO, rest.data(), rest.size());
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count <= 0) {
          break;
        }

        total += static_cast<std::size_t>(count);
      }

      return total;
    }

    // The text `send-keys --stdin` sends: stdin without its trailing line breaks, up to a NUL.
    tbc::val_a<std::string_view> stdinText(tbc::mut_a<ds::String<Memory>> input) {
      input.resize(max_input_bytes + 1);
      const auto count = readInput(input.viewMut());
      if (count > max_input_bytes) {
        throw Failure{"send-keys needs text of 1 to 65536 bytes, or --stdin"};
      }

      input.resize(count);
      while (!input.empty() && (input.view().back() == '\r' || input.view().back() == '\n')) {
        input.truncate(input.size() - 1);
      }

      if (input.empty()) {
        throw Failure{"send-keys needs text of 1 to 65536 bytes, or --stdin"};
      }

      // The text is sent as a zero-terminated string, so embedded NUL ends it.
      return std::string_view{input}.substr(0, input.view().find('\0'));
    }

    // The generation of the pane `wanted`: the current one's, or that of the agent it runs.
    std::uint64_t paneGeneration(ControlSession& session, const Options& options, std::uint64_t wanted) {
      if (options.action == "focus" || options.action == "theme") {
        return current("TELAR_PANE_GENERATION", true);
      }

      const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
      const auto found = std::ranges::find(snapshot.entries, wanted, &AgentSnapshotEntry::pane_id);

      return found == snapshot.entries.end() ? 0 : found->pane_generation;
    }

    void searchPane(ControlSession& session, const Options& options, std::uint64_t wanted, std::string_view text, Output& out) {
      const auto reply = session.template exchange<PaneMatches>(SearchPane{.pane_id = wanted, .needle = text});
      if (reply.pane_id != wanted) {
        throw Failure{"unexpected reply from the runtime"};
      }

      if (options.json) {
        out.text("{\"pane_id\":").number(wanted).text(",\"truncated\":").boolean(reply.truncated).text(",\"matches\":[");
      }

      bool first = true;

      for (const auto& match : reply.matches) {
        if (options.json) {
          out.text(first ? "" : ",").text("{\"x\":").number(match.x).text(",\"y\":").number(match.y).text(",\"len\":").number(match.len).text("}");
        } else {
          out.number(match.y).text(":").number(match.x).text(" length=").number(match.len).text("\n");
        }

        first = false;
      }

      if (options.json) {
        out.text("]}\n");
      }
    }

    // Runs an action on the pane `pane` names, whose text to send or search for is `text`.
    void actOnPane(ControlSession& session, const Options& options, PaneHandle pane, std::string_view text, Output& out) {
      const auto wanted = pane.pane_id;
      const auto generation = pane.pane_generation;

      if (options.action == "read") {
        const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = wanted, .pane_generation = generation, .rows = options.lines, .source = options.source});

        writeText(out, reply, options.json, false);
      } else if (options.action == "send-keys") {
        validateBytes(text, max_input_bytes, false);
        session.template exchange<RequestCompleted>(SendPaneText{.pane_id = wanted, .pane_generation = generation, .mode = PaneTextMode::raw, .text = text});
        if (options.enter) {
          std::this_thread::sleep_for(submit_delay);
          session.template exchange<RequestCompleted>(SendPaneText{.pane_id = wanted, .pane_generation = generation, .mode = PaneTextMode::raw_enter});
        }
      } else if (options.action == "search") {
        searchPane(session, options, wanted, text, out);
      } else if (options.action == "theme") {
        const auto reply = session.template exchange<PaneTheme>(ReadPaneTheme{.pane_id = wanted, .pane_generation = generation});
        if (!reply.theme) {
          throw Failure{"NoTheme"};
        }

        writeTheme(out, *reply.theme);
      } else if (options.action == "focus") {
        const auto reply = session.template exchange<PaneFocusResult>(RequestPaneFocus{.pane_id = wanted, .pane_generation = generation, .direction = *options.direction});

        if (options.json) {
          out.text("{\"changed\":").boolean(reply.outcome == PaneFocusOutcome::focused).text(",\"focused_pane_id\":").number(reply.focused_pane_id).text(",\"reason\":").json(focus_outcomes.at(static_cast<std::size_t>(reply.outcome)), JsonEscapes::control).text("}\n");
        }
      }
    }

    int executePane(Memory& memory, const RuntimePaths<Memory>& paths, Options options, Output& out) {
      ControlSession session{memory, paths.socket.data()};

      session.receiveTimeout(reply_timeout_seconds);
      ds::String<Memory> input{memory};
      // The text to send: the option's, or what stdin gave, which lives here rather than in the options.
      const std::string_view text = options.stdin_text ? stdinText(input) : options.text;

      if (options.action == "list" || options.action == "get") {
        inspectPanes(memory, paths.socket.data(), options, out);
        return 0;
      }

      const auto wanted = paneId(options.target);

      if (options.action == "watch") {
        const auto catalog = paneCatalog(memory, paths.socket.data(), options);

        watchPane(session, options, cataloged(catalog.view(), wanted).pane, out);
        return 0;
      }

      if (wanted == 0) {
        throw Failure{"InvalidPaneId"};
      }

      actOnPane(session, options, {.pane_id = wanted, .pane_generation = paneGeneration(session, options, wanted)}, text, out);
      return 0;
    }

  }

}

namespace telar::runtime::cli {

  int runPane(Memory& memory, const pane_agents::Options& options) {
    using namespace pane_agents;
    const RuntimePaths<Memory> paths{memory, socketOptions(options.socket), process_environment};

    connectRuntime(memory, paths, options.action == "read" || options.action == "send-keys" || options.action == "focus");
    Output out{memory};

    try {
      const auto result = executePane(memory, paths, options, out);

      out.flush();
      return result;
    } catch (const std::exception& error) {
      out.flush();
      return commandFailure("telar pane", error);
    }
  }

}

namespace telar::runtime::cli::project_setup {

  constexpr std::size_t max_recipe_bytes = std::size_t{32} * 1024;
  constexpr std::chrono::seconds wait_timeout{600};

  namespace {

    // Writes into `closing` the brackets `text` leaves open, innermost first, and says how many;
    // none when one closes out of order.
    ds::Option<std::size_t> openBrackets(std::string_view text, std::span<char> closing) {
      std::size_t open = 0;
      bool in_string = false;
      bool escaped = false;

      for (const char byte : text) {
        if (in_string) {
          if (escaped) {
            escaped = false;
          } else if (byte == '\\') {
            escaped = true;
          } else if (byte == '"') {
            in_string = false;
          }
        } else if (byte == '"') {
          in_string = true;
        } else if (byte == '{' || byte == '[') {
          closing[open++] = byte == '{' ? '}' : ']';
        } else if (byte == '}' || byte == ']') {
          if (open == 0 || closing[open - 1] != byte) {
            return ds::none;
          }

          --open;
        }
      }

      std::ranges::reverse(closing.first(open));
      return open;
    }

    // A recipe's text and the completion of it that parsed, which views of the completion point into.
    struct CompletedRecipe {
      std::string_view text;
      std::string_view candidate;

      // Whether `token` of the completion begins within the recipe's own text.
      [[nodiscard]] bool within(std::string_view token) const noexcept {
        return static_cast<std::size_t>(token.data() - candidate.data()) < text.size();
      }
    };

    // Whether each element of the recipe's argv that began within its text is a string.
    bool argvElementsAreStrings(const CompletedRecipe& recipe, JsonValue value) {
      bool strings = true;

      value.eachElement([&](JsonValue element) {
        if (recipe.within(element.encoded()) && !element.encoded().starts_with('"')) {
          strings = false;
        }
      });

      return strings;
    }

    // The diagnostic a member of the completed recipe gives, if any.
    template <Allocator Memory>
    tbc::val_static<const char*> memberDiagnostic(Memory& memory, const CompletedRecipe& recipe, JsonValue key, JsonValue value) {
      const char* diagnostic = nullptr;
      ds::String<Memory> name{memory};

      key.string(name);
      const auto key_end = static_cast<std::size_t>(key.encoded().data() - recipe.candidate.data()) + key.encoded().size();
      if (key_end <= recipe.text.size() && name != "version" && name != "argv") {
        diagnostic = "UnknownField";
      }

      const auto token_started = recipe.within(value.encoded());
      if (token_started && name == "argv" && (!value.encoded().starts_with('[') || !argvElementsAreStrings(recipe, value))) {
        diagnostic = "UnexpectedToken";
      }

      if (token_started && name == "version" && value.encoded().find_first_of("[{tfn") == 0) {
        diagnostic = "UnexpectedToken";
      }

      return diagnostic;
    }

    // The diagnostic of a recipe whose completion `candidate` parsed.
    template <Allocator Memory>
    tbc::val_static<const char*> completionDiagnostic(Memory& memory, std::string_view text, std::string_view candidate) {
      const auto completed = JsonValue::parse(candidate);
      const CompletedRecipe recipe{.text = text, .candidate = candidate};
      const char* diagnostic = "UnexpectedEndOfInput";

      if (completed.encoded().starts_with('{')) {
        completed.eachMember([&](JsonValue key, JsonValue value) {
          if (const auto* const found = memberDiagnostic(memory, recipe, key, value)) {
            diagnostic = found;
          }
        });
      }

      return diagnostic;
    }

    // The shared JSON parser intentionally has one generic syntax error. A recipe
    // keeps a distinct EOF diagnostic when its valid prefix can be completed.
    template <Allocator Memory>
    const char* recipeJsonFailure(Memory& memory, std::string_view text) {
      // The brackets still open, innermost last; a recipe within its byte limit nests no deeper.
      ds::Array<char, max_recipe_bytes> closing{};
      const auto open = openBrackets(text, closing.viewMut());
      if (!open) {
        return "SyntaxError";
      }

      const auto unclosed = closing.view().first(*open);
      constexpr ds::Array completions{"", "\"", "0", "null", ":null", "\":null", "\"\":null", "n\"", "0\"", "00\"", "000\"", "0000\"", "rue", "ue", "e", "alse", "lse", "se", "ull", "ll", "l"};

      for (const std::string_view suffix : completions) {
        if (suffix.empty() && *open == 0) {
          continue;
        }

        ds::String<Memory> candidate{memory, text};

        candidate.append(suffix);
        candidate.append({unclosed.data(), unclosed.size()});
        try {
          return completionDiagnostic(memory, text, candidate);
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a completion that does not parse leaves the next one to try
        }
      }

      return "SyntaxError";
    }

    template <Allocator Memory>
    tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> recipeArguments(tbc::mut_a<Memory> memory, std::string_view text) {
      const auto recipe = [&] {
        try {
          return JsonNode<Memory>::parse(memory, text);
        } catch (const std::exception& error) {
          if (std::string_view{error.what()} == "Duplicate JSON field") {
            throw std::runtime_error{"DuplicateField"};
          }

          throw std::runtime_error{recipeJsonFailure(memory, text)};
        }
      }();
      if (recipe.kind() != JsonKind::object) {
        throw std::runtime_error{"UnexpectedToken"};
      }

      const auto* version = recipe.find("version");
      const auto* argv = recipe.find("argv");
      if (!version || !argv) {
        throw std::runtime_error{"MissingField"};
      }

      if (recipe.children().size() != 2) {
        throw std::runtime_error{"UnknownField"};
      }

      if ((version->kind() != JsonKind::literal && version->kind() != JsonKind::string) || argv->kind() != JsonKind::array || version->text() == "true" || version->text() == "false" || version->text() == "null") {
        throw std::runtime_error{"UnexpectedToken"};
      }

      double number = 0;
      const auto number_text = version->text();
      const auto* const number_end = std::to_address(number_text.end());
      const auto parsed = std::from_chars(number_text.data(), number_end, number);
      // from_chars reports success as the errc of value 0, which names no error.
      if (std::to_underlying(parsed.ec) != 0 || parsed.ptr != number_end || !std::isfinite(number) || std::floor(number) != number) {
        throw std::runtime_error{"InvalidNumber"};
      }

      if (number < 0 || number > std::numeric_limits<std::uint8_t>::max()) {
        throw std::runtime_error{"Overflow"};
      }

      constexpr std::uint8_t recipe_version = 1;

      if (static_cast<std::uint8_t>(number) != recipe_version || argv->children().empty() || argv->children().size() > ExecutionOptions::max_arguments) {
        throw std::runtime_error{"InvalidProjectRecipe"};
      }

      ds::Vec<ds::String<Memory>, Memory> result{memory};

      result.reserve(argv->children().size());
      for (const auto& argument : argv->children()) {
        if (argument.kind() != JsonKind::string) {
          throw std::runtime_error{"UnexpectedToken"};
        }

        result.emplace(memory, argument.text());
      }

      return result;
    }

    template <Allocator Memory>
    tbc::val_a<ds::Option<ds::Vec<ds::String<Memory>, Memory>>> loadRecipe(tbc::mut_a<Memory> memory, std::string_view cwd, bool authorized) {
      const auto path = ds::format(memory, "{}/.telar/setup.json", cwd);
      FileDescriptor parent;
      FileDescriptor file;

      try {
        parent = file_transfer::openParent(path);
        file = file_transfer::openRegular(parent.get(), "setup.json");
      } catch (const std::runtime_error& error) {
        if (std::string_view{error.what()} == "FileNotFound") {
          return ds::none;
        }

        throw;
      }

      if (!authorized) {
        throw std::runtime_error{"ProjectSetupRequiresExplicitSetupFlag"};
      }

      struct stat inode{};
      if (::fstat(file.get(), &inode) != 0 || std::cmp_greater(inode.st_size, max_recipe_bytes)) {
        throw std::runtime_error{"InvalidProjectRecipe"};
      }

      ds::String<Memory> text{memory};

      text.reserve(static_cast<std::size_t>(inode.st_size));
      ds::Array<char, max_recipe_bytes> bytes{};

      for (;;) {
        const auto count = ::read(file.get(), bytes.dataMut(), bytes.size());
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count < 0) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }

        if (count == 0) {
          break;
        }

        if (text.size() + static_cast<std::size_t>(count) > max_recipe_bytes) {
          throw std::runtime_error{"StreamTooLong"};
        }

        text.append({bytes.data(), static_cast<std::size_t>(count)});
      }

      return recipeArguments(memory, text);
    }

    // Starts the recipe and waits for it to succeed. Each reply views the session's storage, so it is
    // asked for here, where the next exchange replaces it.
    void awaitSetup(ControlSession& session, ExecutionRequest request) {
      auto reply = execution::exchange(session, request);

      request.action = ExecutionAction::status;
      request.arguments = {};
      const auto started = std::chrono::steady_clock::now();

      for (;;) {
        if (request.stdout_offset != reply.stdout_offset || request.stderr_offset != reply.stderr_offset) {
          throw std::runtime_error{"SetupOutputRetentionExceeded"};
        }

        writeBytes(STDERR_FILENO, reply.stdout_bytes);
        writeBytes(STDERR_FILENO, reply.stderr_bytes);
        request.stdout_offset += reply.stdout_bytes.size();
        request.stderr_offset += reply.stderr_bytes.size();
        if (execution::finished(reply) && request.stdout_offset == reply.stdout_total && request.stderr_offset == reply.stderr_total) {
          if (reply.state != ExecutionState::exited || reply.exit_code != 0) {
            throw std::runtime_error{"ProjectSetupFailed"};
          }

          return;
        }

        if (std::chrono::steady_clock::now() - started >= wait_timeout) {
          throw std::runtime_error{"SetupWaitTimedOutExecutionContinues"};
        }

        std::this_thread::sleep_for(execution::poll_interval);
        reply = execution::exchange(session, request);
      }
    }

    // Starts a recipe as an execution in `cwd` and, unless `detach`, waits for it to succeed.
    std::uint64_t execute(ControlSession& session, std::string_view cwd, std::span<const ds::String<Memory>> recipe, bool detach) {
      ds::Array<std::string_view, ExecutionOptions::max_arguments> argv;

      for (std::size_t index = 0; index < recipe.size(); ++index) {
        argv.atMut(index) = recipe[index];
      }

      const auto id = randomIdentity();
      const ExecutionRequest request{.action = ExecutionAction::start, .execution_id = id, .cwd = cwd, .arguments = std::span{argv}.first(recipe.size())};

      writeFormatted(STDERR_FILENO, "telar project: setup execution {}; each explicit invocation repeats the recipe\n", id);
      if (detach) {
        static_cast<void>(execution::exchange(session, request));
      } else {
        awaitSetup(session, request);
      }

      return id;
    }

  }

  tbc::val_a<ds::Option<std::uint64_t>> prepare(tbc::mut_a<Memory> memory, ControlSession& session, std::string_view cwd, bool authorized, bool detach) {
    const auto recipe = loadRecipe(memory, cwd, authorized);
    if (!recipe) {
      return ds::none;
    }

    return execute(session, cwd, recipe->view(), detach);
  }

  tbc::val_a<ds::Option<std::uint64_t>> prepare(tbc::mut_a<Memory> memory, std::string_view cwd, bool authorized, bool detach, std::string_view socket) {
    const auto recipe = loadRecipe(memory, cwd, authorized);
    if (!recipe) {
      return ds::none;
    }

    ServerOptions server_options{};

    server_options.socket = socket;
    const RuntimePaths<Memory> paths{memory, server_options, process_environment};

    ensureRuntime(memory, paths);
    ControlSession session{memory, paths.socket.data()};

    session.receiveTimeout(reply_timeout_seconds);
    return execute(session, cwd, recipe->view(), detach);
  }

  namespace {

    // What `project setup` reports of the environment.
    std::string_view environmentState(bool declared, bool detach) noexcept {
      if (!declared) {
        return "not_declared";
      }

      return detach ? "running" : "ready";
    }

  }

  int run(Memory& memory, const Options& options) {
    try {
      const auto id = prepare(memory, options.cwd, true, options.detach, {});

      writeFormatted(STDOUT_FILENO, "{{\"execution_id\":{},\"environment\":{},\"ready\":{}}}\n", orNull(id), quoteJson(environmentState(static_cast<bool>(id), options.detach)), jsonBoolean(id && !options.detach));
      return 0;
    } catch (const std::exception& error) {
      writeFormatted(STDERR_FILENO, "telar project: {}; inspect the execution output, supply missing tools/access on this destination, then explicitly retry project setup\n", error.what());
      return 1;
    }
  }

}

namespace telar::runtime::cli::execution {

}

namespace telar::runtime::cli::project_setup {

}

namespace telar::runtime::cli {

}

namespace telar::runtime::cli::project_setup {

}

namespace telar::runtime::cli {

  namespace {

    // The action the first word names, and the execution id it takes; start without one.
    void executionAction(ExecutionOptions& self, Cursor& cursor, Arguments words) {
      using Action = ExecutionOptions::Action;
      constexpr ds::Array names{"start", "status", "output", "cancel", "forget", "list"};

      if (words.empty()) {
        return;
      }

      for (std::size_t action = 0; action < names.size(); ++action) {
        if (words.front() == std::string_view{names[action]}) {
          self.action = static_cast<Action>(action);
          cursor.next();
          if (self.action != Action::start && self.action != Action::list) {
            self.id = parseUnsigned<std::uint64_t>(cursor.take("MissingExecutionId"));
          }

          return;
        }
      }
    }

    // An option that takes a value.
    void executionValueOption(tbc::mut_a<ExecutionOptions> self, std::string_view arg, Cursor& cursor) {
      const auto value = cursor.take("MissingExecutionOptionValue");

      if (arg == "--cwd") {
        self.cwd = value;
      } else if (arg == "--socket") {
        self.socket = value;
      } else if (arg == "--workspace") {
        self.workspace = parseUnsigned<std::uint64_t>(value);
        if (self.workspace == 0) {
          throw std::invalid_argument{"InvalidWorkspaceId"};
        }
      } else if (arg == "--id") {
        self.id = parseUnsigned<std::uint64_t>(value);
      } else if (arg == "--timeout") {
        self.timeout_seconds = parseUnsigned<std::uint32_t>(value);
      } else if (arg == "--stdout-offset") {
        self.stdout_offset = parseUnsigned<std::uint64_t>(value);
      } else if (arg == "--stderr-offset") {
        self.stderr_offset = parseUnsigned<std::uint64_t>(value);
      } else {
        throw std::invalid_argument{"UnknownExecutionOption"};
      }
    }

    // The command after `--`.
    void executionArguments(tbc::mut_a<ExecutionOptions> self, Arguments command) {
      self.argument_count = command.size();
      if (self.argument_count > ExecutionOptions::max_arguments) {
        throw std::invalid_argument{self.action == ExecutionOptions::Action::start ? "InvalidExecutionArguments" : "InvalidExecutionOptions"};
      }

      std::ranges::copy(command, self.arguments.viewMut().begin());
    }

    // Rejects options the action does not take.
    void validateExecution(const ExecutionOptions& self) {
      using Action = ExecutionOptions::Action;

      if (self.action == Action::start) {
        if (self.argument_count == 0) {
          throw std::invalid_argument{"InvalidExecutionArguments"};
        }

        if (self.json && !self.detach) {
          throw std::invalid_argument{"ForegroundExecutionUsesRawStreams"};
        }

        return;
      }

      const bool id_wrong = self.action == Action::list ? self.id != 0 : self.id == 0;
      if (id_wrong || self.argument_count != 0 || self.detach || self.autoshare || !self.cwd.empty() || self.workspace != 0) {
        throw std::invalid_argument{"InvalidExecutionOptions"};
      }
    }

  }

  namespace {

    // The command starts under `telar share-ports`, which runs it in the execution's own process
    // group and tells this machine's gateway the ports that group listens on, so that the
    // machines connected to it forward them. Its words go before the command's.
    void shareExecutionPorts(tbc::mut_a<ExecutionOptions> self) {
      static const ExecutablePath program;
      constexpr ds::Array<std::string_view, 2> wrapper{"share-ports", "--"};
      const auto added = wrapper.size() + 1;

      if (self.argument_count + added > ExecutionOptions::max_arguments) {
        throw std::invalid_argument{"InvalidExecutionArguments"};
      }

      const auto words = self.arguments.viewMut();

      std::ranges::copy_backward(words.first(self.argument_count), words.first(self.argument_count + added).end());
      words[0] = program.view();
      std::ranges::copy(wrapper, words.subspan(1).begin());
      self.argument_count += added;
    }

  }

  ExecutionOptions ExecutionOptions::parse(Arguments words) {
    ExecutionOptions self;
    Cursor cursor{words};

    executionAction(self, cursor, words);
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--") {
        executionArguments(self, cursor.rest());
        break;
      }

      if (arg == "--detach") {
        self.detach = true;
      } else if (arg == "--json") {
        self.json = true;
      } else if (arg == "--no-stdin") {
        self.stdin_open = false;
      } else if (arg == "--autoshare") {
        self.autoshare = true;
      } else {
        executionValueOption(self, arg, cursor);
      }
    }

    validateExecution(self);
    if (self.autoshare) {
      shareExecutionPorts(self);
    }

    return self;
  }

}

namespace telar::runtime::cli::project_setup {

  Options Options::parse(Arguments words) {
    if (words.size() < 3 || std::string_view{words[0]} != "setup" || std::string_view{words[1]} != "--cwd") {
      throw std::invalid_argument{"InvalidProjectArguments"};
    }

    Options self{.cwd = words[2]};
    if (!self.cwd.starts_with('/')) {
      throw std::invalid_argument{"AbsoluteProjectPathRequired"};
    }

    for (const std::string_view word : words.subspan(3)) {
      if (word == "--detach") {
        self.detach = true;
      } else if (word != "--json") {
        throw std::invalid_argument{"UnknownProjectOption"};
      }
    }

    return self;
  }

}
