module telar.cli.project_setup;

import telar.tbc;
import telar.cli.base.command_error;
import telar.cli.control_session;
import telar.client;
import telar.platform.error;
import telar.platform.sha256;
import telar.sys.posix;
import telar.platform.paths;
import telar.base.text.utf8;
import telar.cli.server;
import telar.platform.primitives;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.base.ds;
import telar.base.memory.containers;
import telar.base.text;
import telar.base.text.json;

namespace telar::runtime::cli::pane_agents {

  constexpr std::size_t max_input_bytes = 65536;
  constexpr std::uint16_t max_read_rows = 2000;
  constexpr std::uint32_t max_timeout_seconds = 86400;
  constexpr std::uint32_t min_interval_ms = 10;
  constexpr std::uint32_t max_interval_ms = 60000;

  constexpr ds::Array<std::string_view, 9> report_states{"working", "blocked", "ready", "exited", "settling", "continuing", "waiting", "idle", "released"};
  constexpr ds::Array<std::string_view, 5> blocked_reasons{"none", "permission", "question", "plan", "other"};
  constexpr ds::Array<std::string_view, 3> session_file_kinds{"claude_transcript", "codex_state", "cursor_meta"};
  constexpr ds::Array<std::string_view, 6> status_names{"unknown", "working", "blocked", "ready", "failed", "done"};

  bool displayText(std::string_view text) {
    return inspectUtf8(text) == Utf8Validation::valid && std::none_of(text.begin(), text.end(), [](unsigned char byte) {
      return byte < 0x20 || byte == 0x7f;
    });
  }

  void socketOption(tbc::view<Options&, tbc::lt::a> options, Cursor& cursor) {
    const auto value = cursor.take("MissingSocketPath");

    if (options.socket) {
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

  Options parsePane(std::span<char* const> words) {
    Cursor cursor{words};
    Options options{.action = cursor.take("MissingPaneAction")};
    const auto action = options.action;
    if (action != "read" && action != "send-keys" && action != "focus" && action != "list" && action != "get" && action != "watch" && action != "search") {
      usage("UnknownPaneAction");
    }

    if (action != "list") {
      options.target = cursor.take("MissingPaneTarget");
      if (options.target != "--current" && !maybeUnsigned(options.target) && !(options.target.starts_with("worktree:") && options.target.size() > std::string_view{"worktree:"}.size())) {
        usage("InvalidPaneId");
      }
    }

    if (action == "focus" && options.target != "--current") {
      usage("FocusRequiresCurrentPane");
    }

    if (action == "search" || action == "send-keys") {
      options.text = cursor.take(action == "search" ? "MissingSearchText" : "MissingSendText");
      options.stdin_text = action == "send-keys" && options.text == "--stdin";
      if (action == "search") {
        if (options.text.empty() || options.text.size() > 128 || inspectUtf8(options.text) != Utf8Validation::valid) {
          usage("InvalidSearchText");
        }
      } else if (!options.stdin_text && (options.text.empty() || options.text.size() > max_input_bytes)) {
        usage("send-keys needs text of 1 to 65536 bytes, or --stdin");
      }
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--json" || (arg == "--jsonl" && action == "watch")) {
        options.json = true;
      } else if (arg == "--socket") {
        socketOption(options, cursor);
      } else if ((arg == "--workspace" || arg == "--tab") && (action == "list" || action == "get" || action == "watch")) {
        auto& target = arg == "--workspace" ? options.workspace : options.tab;
        if (target) {
          usage(arg == "--workspace" ? "DuplicateWorkspaceOption" : "DuplicateTabOption");
        }

        target = cursor.take(arg == "--workspace" ? "MissingWorkspaceId" : "MissingTabId");
        if (*target != "--current") {
          positive(*target, "InvalidIdentity");
        }
      } else if (arg == "--enter" && action == "send-keys") {
        options.enter = true;
      } else if ((arg == "--lines" || arg == "--source") && (action == "read" || action == "watch")) {
        readOption(options, cursor, arg);
      } else if (arg == "--count" && action == "watch" && !options.count) {
        options.count = number<std::uint32_t>(cursor.take("MissingCount"), "InvalidCount");
        if (*options.count == 0) {
          usage("InvalidCount");
        }
      } else if (arg == "--interval-ms" && action == "watch") {
        options.interval = number<std::uint32_t>(cursor.take("MissingInterval"), "InvalidInterval");
        if (options.interval < min_interval_ms || options.interval > max_interval_ms) {
          usage("InvalidInterval");
        }
      } else if (arg == "--direction" && action == "focus" && !cursor.empty() && !options.direction) {
        options.direction = choice<PaneDirection>(cursor.take("UnknownPaneOption"), "InvalidPaneDirection", pane_directions);
      } else {
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
    if (std::find(actions.begin(), actions.end(), action) == actions.end()) {
      usage("UnknownAgentAction");
    }

    if (action != "list") {
      options.target = cursor.take("MissingAgentTarget");
    }

    if (action == "report-command") {
      constexpr ds::Array<std::string_view, 2> phases{"started", "finished"};
      const auto phase = cursor.take("MissingCommandReport");

      options.command.command = cursor.take("MissingCommandReport");
      options.command.phase = choice<AgentCommandPhase>(phase, "InvalidCommandPhase", phases);
    } else if (action == "report-state") {
      options.report.state = choice<AgentReportState>(cursor.take("MissingAgentState"), "InvalidAgentState", report_states);
    } else if (action == "report-title") {
      options.text = cursor.take("MissingAgentTitle");
      if (!options.text.empty() && (options.text.size() > 96 || !displayText(options.text))) {
        usage("InvalidSessionTitle");
      }
    } else if (action == "report-session") {
      options.text = cursor.take("MissingSessionReference");
      if (options.text.empty() || options.text.size() > 64) {
        usage("InvalidSessionReference");
      }
    } else if (action == "prompt") {
      options.text = cursor.take("MissingPromptText");
      if (options.text.size() > max_input_bytes) {
        usage("InvalidPromptText");
      }
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--json") {
        options.json = true;
      } else if (arg == "--socket") {
        socketOption(options, cursor);
      } else if (arg == "--provider" && action == "report-command") {
        options.command.provider = cursor.take("MissingProvider");
      } else if (arg == "--tool-call" && action == "report-command") {
        options.command.tool_call_id = cursor.take("MissingToolCall");
      } else if (arg == "--cwd" && action == "report-command") {
        options.command.cwd = cursor.take("MissingCwd");
      } else if (arg == "--session" && action == "report-command") {
        options.command.session = cursor.take("MissingSessionReference");
      } else if (arg == "--exit-code" && action == "report-command") {
        options.command.exit_code = signedNumber<std::int32_t>(cursor.take("MissingExitCode"), "InvalidExitCode");
      } else if (arg == "--blocked-reason" && action == "report-state") {
        options.report.blocked_reason = choice<AgentBlockedReason>(cursor.take("MissingBlockedReason"), "InvalidBlockedReason", blocked_reasons);
      } else if (arg == "--event" && action == "report-state") {
        options.report.event = cursor.take("MissingAgentEvent");
      } else if (arg == "--session" && action == "report-state") {
        options.report.session = cursor.take("MissingSessionReference");
      } else if (arg == "--session-file" && action == "report-state") {
        options.report.session_file = cursor.take("MissingSessionFile");
      } else if (arg == "--session-file-kind" && action == "report-state") {
        options.report.session_file_kind = choice<AgentSessionFileKind>(cursor.take("MissingSessionFileKind"), "InvalidSessionFileKind", session_file_kinds);
      } else if (arg == "--interrupt" && action == "prompt") {
        options.interrupt = true;
      } else if (arg == "--wait" && action == "prompt") {
        options.wait = true;
      } else if (arg == "--until" && action == "wait") {
        auto status = cursor.take("MissingWaitStatus");

        options.finished = status == "finished";
        if (status == "idle") {
          status = "ready";
        }

        if (!options.finished) {
          options.until = choice<AgentStatus>(status, "InvalidWaitStatus", status_names);
          if (options.until == AgentStatus::unknown) {
            usage("InvalidWaitStatus");
          }
        }
      } else if (arg == "--timeout" && (action == "wait" || action == "prompt")) {
        auto text = cursor.take("MissingTimeout");

        while (text.ends_with('s')) {
          text.remove_suffix(1);
        }

        options.timeout = number<std::uint32_t>(text, "InvalidTimeout");
        if (options.timeout == 0 || options.timeout > max_timeout_seconds) {
          usage("InvalidTimeout");
        }
      } else if ((arg == "--lines" || arg == "--source") && action == "read") {
        readOption(options, cursor, arg);
      } else {
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

    if (value.find('\0') != std::string_view::npos) {
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

      validateBytes(report.session_file, 1024);
      validateBytes(report.event, 96);
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

      validateBytes(command.provider, 64, false);
      validateBytes(command.tool_call_id, 256);
      validateBytes(command.command, max_input_bytes, false);
      validateBytes(command.cwd, 4096);
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

    options.socket = socket ? socket : "";
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

    if (startRuntime(memory, ServerOptions{}, paths) != RuntimeStart::listening) {
      throw CommandError{"RuntimeUnavailable"};
    }
  }

  void writeAgent(Output& out, const AgentSnapshotEntry& agent, bool json) {
    const auto provider = agent.provider_name.empty() ? std::string_view{"unknown"} : agent.provider_name;
    const auto status = status_names[static_cast<std::size_t>(agent.status)];

    if (json) {
      out.text("{\"pane_id\":").number(agent.pane_id).text(",\"pane_generation\":").number(agent.pane_generation).text(",\"workspace_id\":").number(agent.location.workspace.id).text(",\"tab_id\":").number(agent.location.tab_id).text(",\"pane_index\":").number(agent.pane_index).text(",\"provider\":").json(provider, JsonEscapes::control).text(",\"provider_index\":").number(static_cast<unsigned>(agent.provider)).text(",\"status\":").json(status, JsonEscapes::control);
      out.text(",\"workspace\":").json(agent.workspace_label, JsonEscapes::control).text(",\"tab\":").json(agent.tab_label, JsonEscapes::control).text(",\"title\":").json(agent.session_title, JsonEscapes::control).text(",\"cwd\":").json(agent.cwd_label, JsonEscapes::control).text(",\"blocked_reason\":").json(blocked_reasons[static_cast<std::size_t>(agent.blocked_reason)], JsonEscapes::control).text(",\"status_age_s\":").number(agent.status_age_s).text(",\"worktree_id\":").number(agent.work_tree).text(",\"last_event\":").json(agent.last_event, JsonEscapes::control);
      out.text(",\"plan\":{\"done\":").number(agent.plan_done).text(",\"total\":").number(agent.plan_total).text(",\"step\":").json(agent.plan_step, JsonEscapes::control).text("},\"final_message\":").json(agent.final_message, JsonEscapes::control).text(",\"session_id\":\"");
      ds::Array<char, 2 * sizeof(agent.session_id)> session;

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

    numeric(agent.pane_id, 6);
    numeric(agent.pane_generation, 5);
    column(status, 9);
    column(provider, 8);
    column(agent.workspace_label, 18);
    column(agent.tab_label, 14);
    out.text(agent.session_title).text("\n");
  }

  constexpr std::string_view agent_header = "PANE  GEN  STATUS   PROV    WORKSPACE         TAB           TITLE\n";

  void writeOne(Output& out, const AgentSnapshotEntry& agent, bool json) {
    if (!json) {
      out.text(agent_header);
    }

    writeAgent(out, agent, json);
    if (json) {
      out.text("\n");
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
      std::fprintf(stderr, "telar %s: older rows were omitted\n", agent ? "agent" : "pane");
    }

    if (!agent && reply.exit_code) {
      std::fprintf(stderr, "telar pane: the command exited with %d\n", *reply.exit_code);
    }
  }

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
  tbc::view<ds::Vec<PaneRecord, Memory>, tbc::lt::a> paneCatalog(tbc::view<Memory&, tbc::lt::a> memory, const char* socket, const Options& options) {
    ControlSession session{memory, socket};

    session.receiveTimeout(30);
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

  template <Allocator Memory>
  std::uint64_t worktreeId(Memory& memory, const char* socket, std::string_view reference) {
    ControlSession session{memory, socket};

    session.receiveTimeout(30);
    const auto list = runtimeList(session);

    for (const bool branch : {true, false}) {
      ds::Option<std::uint64_t> found;

      for (const auto& tree : list.worktrees) {
        if (branch ? tree.branch == reference : equalTitle(tree.title, reference)) {
          if (found) {
            throw Failure{"more than one worktree has that branch or title; name it by the other"};
          }

          found = tree.worktree;
        }
      }

      if (found) {
        return *found;
      }
    }

    throw Failure{"no tracked worktree matches that branch or title", 2};
  }

  tbc::view<AgentSnapshotEntry, tbc::lt::a> resolve(tbc::view<const AgentSnapshot&, tbc::lt::a> snapshot, std::string_view target, ds::Option<std::uint64_t> worktree) {
    const auto wanted = target == "--current" ? ds::Option{current("TELAR_PANE_ID")} : maybeUnsigned(target);
    ds::Option<AgentSnapshotEntry> found;

    for (const auto& entry : snapshot.entries) {
      if (worktree ? entry.work_tree == *worktree : wanted ? entry.pane_id == *wanted
                                                           : equalTitle(entry.session_title, target)) {
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

    const auto socket = options.socket ? std::string_view{options.socket} : environment.lookup("TELAR_SOCKET");
    if (!socket.empty() && socket != own.view()) {
      return ds::none;
    }

    if (*id == 0) {
      throw Failure{"InvalidPaneId"};
    }

    return id;
  }

  int commandFailure(const char* family, const std::exception& error) {
    const auto* system = dynamic_cast<const SystemError*>(&error);
    const auto socket_timeout = dynamic_cast<const SocketError*>(&error) && (sys::lastError() == EAGAIN || sys::lastError() == EWOULDBLOCK);
    const auto timeout = socket_timeout || (system && (system->code() == EAGAIN || system->code() == EWOULDBLOCK));

    std::fprintf(stderr, "%s: %s\n", family, timeout ? "RuntimeTimeout" : error.what());
    if (timeout) {
      return 1;
    }

    if (const auto* failure = dynamic_cast<const Failure*>(&error)) {
      return failure->status();
    }

    if (const auto* failure = dynamic_cast<const ControlFailure*>(&error)) {
      return (failure->code() == FailureCode::pane_not_found || failure->code() == FailureCode::pane_exited || (std::string_view{family} == "telar agent" && failure->code() == FailureCode::worktree_not_found)) ? 2 : 1;
    }

    return 1;
  }

  void interruptAgent(ControlSession& session, const AgentSnapshotEntry& agent) {
    session.template exchange<RequestCompleted>(InterruptAgent{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation});
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
        std::fprintf(stderr, "telar agent: timed out after %us; agent is %.*s\n", options.timeout, static_cast<int>(status_names[static_cast<std::size_t>(agent.status)].size()), status_names[static_cast<std::size_t>(agent.status)].data());
        return 3;
      }

      std::this_thread::sleep_for(poll_interval);
    }
  }

  void settleAgent(ControlSession& session, AgentSnapshotEntry agent) {
    const auto pane = agent.pane_id;

    interruptAgent(session, agent);
    const auto deadline = std::chrono::system_clock::now() + interrupt_settle;

    while (std::chrono::system_clock::now() < deadline) {
      std::this_thread::sleep_for(poll_interval);
      const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
      const auto found = std::find_if(snapshot.entries.begin(), snapshot.entries.end(), [&](const auto& entry) {
        return entry.pane_id == pane;
      });
      if (found == snapshot.entries.end()) {
        throw Failure{"no agent matches that target", 2};
      }

      if (found->status != AgentStatus::working) {
        return;
      }
    }

    throw Failure{"InterruptNotSettled"};
  }

  int promptAgent(ControlSession& session, const Options& options, AgentSnapshotEntry agent, Output& out) {
    const auto pane = agent.pane_id;
    const auto generation = agent.pane_generation;

    if (options.interrupt && agent.status == AgentStatus::working) {
      settleAgent(session, agent);
    }

    session.template exchange<RequestCompleted>(SendPaneText{.pane_id = pane, .pane_generation = generation, .mode = PaneTextMode::prompt, .text = options.text, .sender = senderPane(options, pane)});
    if (!options.wait) {
      return 0;
    }

    const auto start_deadline = std::chrono::system_clock::now() + start_grace;
    const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds{options.timeout};
    bool started = false;

    for (;;) {
      const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
      const auto found = std::find_if(snapshot.entries.begin(), snapshot.entries.end(), [&](const auto& entry) {
        return entry.pane_id == pane;
      });
      if (found == snapshot.entries.end() || found->pane_generation != generation) {
        throw Failure{"no agent matches that target", 2};
      }

      agent = *found;
      if (agent.status == AgentStatus::working) {
        started = true;
      } else if (started || agent.status == AgentStatus::blocked || agent.status == AgentStatus::failed) {
        writeOne(out, agent, options.json);
        return agent.status == AgentStatus::failed ? 1 : 0;
      } else if (std::chrono::system_clock::now() >= start_deadline) {
        std::fprintf(stderr, "telar agent: the agent did not start working within 5s\n");
        return 3;
      }

      if (std::chrono::system_clock::now() >= deadline) {
        std::fprintf(stderr, "telar agent: timed out after %us; agent is still working\n", options.timeout);
        return 3;
      }

      std::this_thread::sleep_for(poll_interval);
    }
  }

  void reportAgent(ControlSession& session, const Options& options, const std::pair<std::uint64_t, std::uint64_t>& pane, Output& out) {
    try {
      session.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = pane.first, .pane_generation = pane.second});
    } catch (const std::exception&) {
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

  int executeAgent(Memory& memory, const RuntimePaths<Memory>& paths, const Options& options, Output& out) {
    ControlSession session{memory, paths.socket.data()};

    session.receiveTimeout(30);
    const bool report = options.action == "report-title" || options.action == "report-state" || options.action == "report-command";
    ds::Option<std::uint64_t> tree;
    constexpr std::string_view prefix = "worktree:";
    if (options.target.starts_with(prefix) && options.target.size() > prefix.size()) {
      if (report) {
        ControlSession catalog{memory, paths.socket.data()};

        catalog.receiveTimeout(30);
        runtimeList(catalog);
      } else {
        tree = worktreeId(memory, paths.socket.data(), options.target.substr(prefix.size()));
      }
    }

    if (report && options.target == "--current") {
      reportAgent(session, options, {current("TELAR_PANE_ID"), current("TELAR_PANE_GENERATION", true)}, out);
      return 0;
    }

    const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});

    if (options.action == "list") {
      if (options.json) {
        out.text("{\"revision\":").number(snapshot.revision).text(",\"agents\":[");
      } else {
        out.text(agent_header);
      }

      bool first = true;

      for (const auto& agent : snapshot.entries) {
        if (options.json && !first) {
          out.text(",");
        }

        writeAgent(out, agent, options.json);
        first = false;
      }

      if (options.json) {
        out.text("]}\n");
      }

      return 0;
    }

    // Manual reports resolve the agent snapshot without a worktree catalog.
    if (report && options.target.starts_with(prefix) && options.target.size() > prefix.size()) {
      throw Failure{"WorktreeCatalogMissing"};
    }

    if (options.action == "wait") {
      return waitAgent(session, options, tree, out);
    }

    if (options.action == "prompt") {
      const auto refreshed = session.template exchange<AgentSnapshot>(QueryAgents{});
      const auto again = resolve(refreshed, options.target, tree);

      return promptAgent(session, options, again, out);
    }

    const auto agent = resolve(snapshot, options.target, tree);

    if (report) {
      reportAgent(session, options, {agent.pane_id, agent.pane_generation}, out);
    } else if (options.action == "get") {
      writeOne(out, agent, options.json);
    } else if (options.action == "read") {
      const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .rows = options.lines, .source = options.source});

      writeText(out, reply, options.json, true);
    } else if (options.action == "interrupt") {
      Output saved{memory};

      writeOne(saved, agent, options.json);
      interruptAgent(session, agent);
      out.text(saved.data);
    } else if (options.action == "acknowledge") {
      const auto pane = agent.pane_id;
      const auto generation = agent.pane_generation;

      session.send(AcknowledgeAgent{.pane_id = pane, .pane_generation = generation});
      const auto updated = session.template exchange<AgentSnapshot>(QueryAgents{});
      const auto found = std::find_if(updated.entries.begin(), updated.entries.end(), [&](const auto& entry) {
        return entry.pane_id == pane;
      });
      if (found == updated.entries.end() || found->pane_generation != generation) {
        throw Failure{"no agent matches that target", 2};
      }

      if (found->status == AgentStatus::done) {
        throw Failure{"AgentAcknowledgementNotApplied"};
      }

      writeOne(out, *found, options.json);
    } else if (options.action == "report-session") {
      validateSession(options.text);
      session.template exchange<RequestCompleted>(ReportAgentSession{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .session = options.text});
    }

    return 0;
  }

}

namespace telar::runtime::cli {

  int runAgent(Memory& memory, const pane_agents::Options& options) {
    using namespace pane_agents;
    const RuntimePaths paths{memory, socketOptions(options.socket), process_environment};

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

  std::string_view stateName(ExecutionState state) {
    constexpr ds::Array names{"starting", "running", "exited", "failed"};

    return names.at(static_cast<std::size_t>(state));
  }

  bool finished(const ExecutionReply& reply) {
    return reply.state == ExecutionState::exited || reply.state == ExecutionState::failed;
  }

  tbc::view<ExecutionReply, tbc::lt::a> exchange(tbc::view<ControlSession&, tbc::lt::a> session, ExecutionRequest request) {
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

      output.print("{{\"execution_id\":{},\"workspace_id\":{},\"state\":{},\"exit_code\":{}}}", reply.execution_id, reply.workspace_id, quoteJson(stateName(reply.state)), orNull(finished(reply) ? ds::Option{reply.exit_code} : ds::none));
      request.execution_id = reply.execution_id;
    }

    output.print("]\n");
    output.flush();
  }

  // Forgets a finished execution; a refusal leaves it retained, as before.
  void release(ControlSession& session, ExecutionRequest request) noexcept {
    request.action = ExecutionAction::forget;
    try {
      exchange(session, request);
    } catch (...) {
    }
  }

  int observe(ControlSession& session, ExecutionRequest request, ExecutionReply reply, const ExecutionOptions& options) {
    const auto started = std::chrono::steady_clock::now();
    bool stdin_open = request.stdin_open;
    const auto stdout_end = reply.stdout_total;
    const auto stderr_end = reply.stderr_total;

    request.action = ExecutionAction::status;
    request.arguments = {};
    request.cwd = {};
    for (;;) {
      writeStreams(request, reply);
      if (options.action == ExecutionOptions::Action::output) {
        if (request.stdout_offset >= stdout_end && request.stderr_offset >= stderr_end) {
          return 0;
        }
      } else {
        if (finished(reply) && request.stdout_offset == reply.stdout_total && request.stderr_offset == reply.stderr_total) {
          if (reply.state == ExecutionState::failed) {
            writeFormatted(STDERR_FILENO, "telar exec: {}\n", textBytes(reply.failure));
          }

          const auto status = std::clamp(reply.exit_code, 0, 255);
          // The whole result reached this process: keeping it would only fill
          // the runtime's bounded table. A status equal to telar's own 124/125
          // stays, so `exec status` can still tell them apart. `reply` views
          // the session buffer, so the exchange comes after its last read.
          if (options.action == ExecutionOptions::Action::start && status != timeout_status && status != failure_status) {
            release(session, request);
          }

          return status;
        }

        if (options.timeout_seconds != 0 && std::chrono::steady_clock::now() - started >= std::chrono::seconds{options.timeout_seconds}) {
          writeFormatted(STDERR_FILENO, "telar exec: wait timed out; execution {} continues\n", request.execution_id);
          return timeout_status;
        }

        if (stdin_open && reply.stdin_open && reply.input_available >= max_chunk) {
          pollfd input{.fd = STDIN_FILENO, .events = POLLIN, .revents = 0};
          if (::poll(&input, 1, 0) > 0) {
            ds::Array<Byte, max_chunk> bytes;
            const auto count = ::read(STDIN_FILENO, bytes.dataMut(), bytes.size());
            if (count < 0) {
              throw std::runtime_error{"ExecutionStdinFailed"};
            }

            auto chunk = request;

            chunk.action = count == 0 ? ExecutionAction::eof : ExecutionAction::input;
            chunk.bytes = std::span{bytes}.first(static_cast<std::size_t>(count));
            chunk.input_offset = reply.input_offset;
            reply = exchange(session, chunk);
            stdin_open = count != 0;
            continue;
          }
        }

        if (reply.stdout_bytes.empty() && reply.stderr_bytes.empty()) {
          std::this_thread::sleep_for(poll_interval);
        }
      }

      reply = exchange(session, request);
    }
  }

  int start(ControlSession& session, const ExecutionOptions& options) {
    if (options.action == ExecutionOptions::Action::list) {
      list(session);
      return 0;
    }

    const auto action = options.action == ExecutionOptions::Action::start ? ExecutionAction::start : options.action == ExecutionOptions::Action::cancel ? ExecutionAction::cancel
                                                                                                 : options.action == ExecutionOptions::Action::forget   ? ExecutionAction::forget
                                                                                                                                                        : ExecutionAction::status;
    ExecutionRequest request{
        .action = action,
        .execution_id = options.id == 0 ? randomIdentity() : options.id,
        .workspace_id = options.workspace,
        .stdout_offset = options.stdout_offset,
        .stderr_offset = options.stderr_offset,
        .stdin_open = options.stdin_open && !options.detach,
        .cwd = options.cwd,
        .arguments = std::span{options.arguments}.first(options.argument_count),
    };

    try {
      const auto reply = exchange(session, request);

      if (options.action == ExecutionOptions::Action::status || options.action == ExecutionOptions::Action::cancel || options.action == ExecutionOptions::Action::forget || options.detach) {
        writeStatusJson(reply);
        return 0;
      }

      return observe(session, request, reply, options);
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
      const RuntimePaths paths{memory, server_options, process_environment};

      ensureRuntime(memory, paths);
      ControlSession session{memory, paths.socket.data()};

      session.receiveTimeout(30);
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

  void writePane(Output& out, const PaneRecord& entry, bool json) {
    const auto& pane = entry.pane;
    const auto lifecycle = lifecycles.at(static_cast<std::size_t>(pane.lifecycle));

    if (json) {
      out.text("{\"workspace_id\":").number(entry.location.workspace.id).text(",\"tab_id\":").number(entry.location.tab_id).text(",\"position\":").number(entry.position).text(",\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"lifecycle\":").json(lifecycle, JsonEscapes::standard).text("}");
    } else {
      out.number(entry.location.workspace.id).text("\t").number(entry.location.tab_id).text("\t").number(pane.pane_id).text("\t").number(pane.pane_generation).text("\t").text(lifecycle).text("\n");
    }
  }

  void inspectPanes(Memory& memory, const char* socket, const Options& options, Output& out) {
    const auto catalog = paneCatalog(memory, socket, options);

    if (options.action == "get") {
      const auto wanted = paneId(options.target);

      for (const auto& entry : catalog) {
        if (entry.pane.pane_id == wanted) {
          writePane(out, entry, options.json);
          if (options.json) {
            out.text("\n");
          }

          return;
        }
      }

      throw Failure{controlFailureDescription(FailureCode::pane_not_found), 2};
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
    ds::Option<ds::Array<unsigned char, SHA256_DIGEST_LENGTH>> previous;
    bool previous_truncated = false;
    std::uint64_t count = 0;

    for (;;) {
      const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .rows = options.lines, .source = options.source});
      if (reply.pane_id != pane.pane_id) {
        throw Failure{"unexpected reply from the runtime"};
      }

      ds::Array<unsigned char, SHA256_DIGEST_LENGTH> digest;

      SHA256(reinterpret_cast<const unsigned char*>(reply.text.data()), reply.text.size(), digest.dataMut());
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

  int executePane(Memory& memory, const RuntimePaths<Memory>& paths, Options options, Output& out) {
    ControlSession session{memory, paths.socket.data()};

    session.receiveTimeout(30);
    ds::String<Memory> input{memory};
    // The text to send: the option's, or what stdin gave, which lives here rather than in the options.
    std::string_view text = options.text;

    if (options.stdin_text) {
      input.resize(max_input_bytes + 1);
      const auto count = std::fread(input.dataMut(), 1, input.size(), stdin);
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
      text = std::string_view{input}.substr(0, input.view().find('\0'));
    }

    if (options.action == "list" || options.action == "get") {
      inspectPanes(memory, paths.socket.data(), options, out);
      return 0;
    }

    const auto wanted = paneId(options.target);

    if (options.action == "watch") {
      const auto catalog = paneCatalog(memory, paths.socket.data(), options);

      for (const auto& entry : catalog) {
        if (entry.pane.pane_id == wanted) {
          watchPane(session, options, entry.pane, out);
          return 0;
        }
      }

      throw Failure{controlFailureDescription(FailureCode::pane_not_found), 2};
    }

    if (wanted == 0) {
      throw Failure{"InvalidPaneId"};
    }

    std::uint64_t generation = 0;

    if (options.action == "focus") {
      generation = current("TELAR_PANE_GENERATION", true);
    } else {
      const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});

      for (const auto& agent : snapshot.entries) {
        if (agent.pane_id == wanted) {
          generation = agent.pane_generation;
          break;
        }
      }
    }

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
    } else if (options.action == "focus") {
      const auto reply = session.template exchange<PaneFocusResult>(RequestPaneFocus{.pane_id = wanted, .pane_generation = generation, .direction = *options.direction});

      if (options.json) {
        out.text("{\"changed\":").boolean(reply.outcome == PaneFocusOutcome::focused).text(",\"focused_pane_id\":").number(reply.focused_pane_id).text(",\"reason\":").json(focus_outcomes.at(static_cast<std::size_t>(reply.outcome)), JsonEscapes::control).text("}\n");
      }
    }

    return 0;
  }

}

namespace telar::runtime::cli {

  int runPane(Memory& memory, const pane_agents::Options& options) {
    using namespace pane_agents;
    const RuntimePaths paths{memory, socketOptions(options.socket), process_environment};

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

  constexpr std::size_t max_recipe_bytes = 32 * 1024;
  constexpr std::chrono::seconds wait_timeout{600};

  // The shared JSON parser intentionally has one generic syntax error. A recipe
  // keeps a distinct EOF diagnostic when its valid prefix can be completed.
  template <Allocator Memory>
  const char* recipeJsonFailure(Memory& memory, std::string_view text) {
    // The brackets still open, innermost last; a recipe within its byte limit nests no deeper.
    ds::Array<char, max_recipe_bytes> closing;
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
        closing.atMut(open++) = byte == '{' ? '}' : ']';
      } else if (byte == '}' || byte == ']') {
        if (open == 0 || closing[open - 1] != byte) {
          return "SyntaxError";
        }

        --open;
      }
    }

    const auto unclosed = closing.viewMut().first(open);

    std::ranges::reverse(unclosed);
    constexpr ds::Array completions{"", "\"", "0", "null", ":null", "\":null", "\"\":null", "n\"", "0\"", "00\"", "000\"", "0000\"", "rue", "ue", "e", "alse", "lse", "se", "ull", "ll", "l"};

    for (const std::string_view suffix : completions) {
      if (suffix.empty() && open == 0) {
        continue;
      }

      ds::String<Memory> candidate{memory, text};

      candidate.append(suffix);
      candidate.append({unclosed.data(), unclosed.size()});
      try {
        const auto completed = JsonValue::parse(candidate);
        const char* diagnostic = "UnexpectedEndOfInput";

        if (completed.encoded().starts_with('{')) {
          completed.eachMember([&](JsonValue key, JsonValue value) {
            ds::String<Memory> name{memory};

            key.string(name);
            const auto key_end = static_cast<std::size_t>(key.encoded().data() - candidate.data()) + key.encoded().size();
            if (key_end <= text.size() && name != "version" && name != "argv") {
              diagnostic = "UnknownField";
            }

            const auto token_started = static_cast<std::size_t>(value.encoded().data() - candidate.data()) < text.size();
            if (token_started && name == "argv") {
              if (!value.encoded().starts_with('[')) {
                diagnostic = "UnexpectedToken";
              } else {
                value.eachElement([&](JsonValue element) {
                  const auto started = static_cast<std::size_t>(element.encoded().data() - candidate.data()) < text.size();
                  if (started && !element.encoded().starts_with('"')) {
                    diagnostic = "UnexpectedToken";
                  }
                });
              }
            }

            if (token_started && name == "version" && value.encoded().find_first_of("[{tfn") == 0) {
              diagnostic = "UnexpectedToken";
            }
          });
        }

        return diagnostic;
      } catch (const std::exception&) {
      }
    }

    return "SyntaxError";
  }

  template <Allocator Memory>
  tbc::view<ds::Vec<ds::String<Memory>, Memory>, tbc::lt::a> recipeArguments(tbc::view<Memory&, tbc::lt::a> memory, std::string_view text) {
    auto recipe = [&] {
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
    const auto parsed = std::from_chars(number_text.data(), number_text.data() + number_text.size(), number);
    if (parsed.ec != std::errc{} || parsed.ptr != number_text.data() + number_text.size() || !std::isfinite(number) || std::floor(number) != number) {
      throw std::runtime_error{"InvalidNumber"};
    }

    if (number < 0 || number > std::numeric_limits<std::uint8_t>::max()) {
      throw std::runtime_error{"Overflow"};
    }

    if (number != 1 || argv->children().empty() || argv->children().size() > ExecutionOptions::max_arguments) {
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
  tbc::view<ds::Option<ds::Vec<ds::String<Memory>, Memory>>, tbc::lt::a> loadRecipe(tbc::view<Memory&, tbc::lt::a> memory, std::string_view cwd, bool authorized) {
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
    if (::fstat(file.get(), &inode) != 0 || inode.st_size > static_cast<off_t>(max_recipe_bytes)) {
      throw std::runtime_error{"InvalidProjectRecipe"};
    }

    ds::String<Memory> text{memory};

    text.reserve(static_cast<std::size_t>(inode.st_size));
    ds::Array<char, max_recipe_bytes> bytes;

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

  void awaitSetup(ControlSession& session, ExecutionRequest request, ExecutionReply reply) {
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
    ExecutionRequest request{.action = ExecutionAction::start, .execution_id = id, .cwd = cwd, .arguments = std::span{argv}.first(recipe.size())};

    writeFormatted(STDERR_FILENO, "telar project: setup execution {}; each explicit invocation repeats the recipe\n", id);
    const auto reply = execution::exchange(session, request);

    if (!detach) {
      awaitSetup(session, request, reply);
    }

    return id;
  }

  tbc::view<ds::Option<std::uint64_t>, tbc::lt::a> prepare(tbc::view<Memory&, tbc::lt::a> memory, ControlSession& session, std::string_view cwd, bool authorized, bool detach) {
    const auto recipe = loadRecipe(memory, cwd, authorized);
    if (!recipe) {
      return ds::none;
    }

    return execute(session, cwd, recipe->view(), detach);
  }

  tbc::view<ds::Option<std::uint64_t>, tbc::lt::a> prepare(tbc::view<Memory&, tbc::lt::a> memory, std::string_view cwd, bool authorized, bool detach, std::string_view socket) {
    const auto recipe = loadRecipe(memory, cwd, authorized);
    if (!recipe) {
      return ds::none;
    }

    ServerOptions server_options{};

    server_options.socket = socket;
    const RuntimePaths paths{memory, server_options, process_environment};

    ensureRuntime(memory, paths);
    ControlSession session{memory, paths.socket.data()};

    session.receiveTimeout(30);
    return execute(session, cwd, recipe->view(), detach);
  }

  int run(Memory& memory, const Options& options) {
    try {
      const auto id = prepare(memory, options.cwd, true, options.detach, {});

      writeFormatted(STDOUT_FILENO, "{{\"execution_id\":{},\"environment\":{},\"ready\":{}}}\n", orNull(id), quoteJson(!id ? "not_declared" : options.detach ? "running"
                                                                                                                                                                            : "ready"),
          jsonBoolean(id && !options.detach));
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

  ExecutionOptions ExecutionOptions::parse(Arguments words) {
    ExecutionOptions self;
    Cursor cursor{words};
    constexpr ds::Array names{"start", "status", "output", "cancel", "forget", "list"};

    if (!words.empty()) {
      for (std::size_t action = 0; action < names.size(); ++action) {
        if (words.front() == std::string_view{names[action]}) {
          self.action = static_cast<Action>(action);
          cursor.next();
          if (self.action != Action::start && self.action != Action::list) {
            self.id = parseUnsigned<std::uint64_t>(cursor.take("MissingExecutionId"));
          }

          break;
        }
      }
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--") {
        const auto command = cursor.rest();

        self.argument_count = command.size();
        if (self.argument_count > max_arguments) {
          throw std::invalid_argument{self.action == Action::start ? "InvalidExecutionArguments" : "InvalidExecutionOptions"};
        }

        std::ranges::copy(command, self.arguments.viewMut().begin());
        break;
      }

      if (arg == "--detach") {
        self.detach = true;
      } else if (arg == "--json") {
        self.json = true;
      } else if (arg == "--no-stdin") {
        self.stdin_open = false;
      } else {
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
    }

    if (self.action == Action::start) {
      if (self.argument_count == 0) {
        throw std::invalid_argument{"InvalidExecutionArguments"};
      }

      if (self.json && !self.detach) {
        throw std::invalid_argument{"ForegroundExecutionUsesRawStreams"};
      }
    } else if ((self.action == Action::list ? self.id != 0 : self.id == 0) || self.argument_count != 0 || self.detach || !self.cwd.empty() || self.workspace != 0) {
      throw std::invalid_argument{"InvalidExecutionOptions"};
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
