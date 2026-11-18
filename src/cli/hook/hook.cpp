module;
#include "telar_platform/trace_macro.hpp"

module telar.cli.hook;
import telar.platform.sha256;
import telar.sys.posix;
import telar.cli.control_session;
import telar.base.memory.containers;
import telar.base.text.utf8;
import telar.git.checkout;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.wire.agents;
import telar.wire.layout;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.ds;

namespace telar::runtime::cli::hooks {

  tbc::view<ds::Option<ReportAgent>, tbc::lt::a> claudeLifecycle(tbc::view<Payload&, tbc::lt::a> input, tbc::view<FixedText<96>&, tbc::lt::a> event) {
    const auto name = input.event();

    if (input.subagent()) {
      return name == "PreToolUse" || name == "PostToolUse" ? ds::Option{ReportAgent{.state = AgentReportState::continuing}} : ds::none;
    }

    const auto file = input.fields.text("transcript_path");
    ReportAgent report{.session = sessionReference(input.session()), .session_file = file.size() <= 1024 ? file : ""};

    if (name == "SessionStart") {
      report.state = AgentReportState::ready;
    } else if (name == "UserPromptSubmit") {
      report.state = AgentReportState::working;
    } else if (name == "PreToolUse" || name == "PostToolUse") {
      toolEvent(event, input);
      report.state = AgentReportState::working;
      const auto tool = input.fields.text("tool_name");
      if (name == "PreToolUse" && (tool == "AskUserQuestion" || tool == "ExitPlanMode")) {
        report.state = AgentReportState::blocked;
        report.blocked_reason = tool == "AskUserQuestion" ? AgentBlockedReason::question : AgentBlockedReason::plan;
        if (tool == "AskUserQuestion") {
          questionEvent(event, input);
        }
      }
    } else if (name == "Stop") {
      report.state = input.running_subagents == 0 ? AgentReportState::ready : AgentReportState::waiting;
      if (input.running_subagents == 0) {
        eventLine(event, input.fields.text("last_assistant_message"));
      } else {
        backgroundEvent(event, input.running_subagents);
      }
    } else if (name == "SessionEnd") {
      report.state = AgentReportState::exited;
      report.session = {};
    } else if (name == "Notification") {
      const auto notification = input.fields.text("notification_type");
      if (notification == "idle_prompt") {
        report.state = AgentReportState::idle;
      } else if (notification == "permission_prompt" || notification == "elicitation_dialog" || notification == "elicitation_url_dialog" || notification == "agent_needs_input") {
        report.state = AgentReportState::blocked;
        report.blocked_reason = notification == "permission_prompt" ? AgentBlockedReason::permission : AgentBlockedReason::question;
        eventLine(event, input.fields.text("message"));
      } else {
        return ds::none;
      }
    } else {
      return ds::none;
    }

    report.event = event.view();
    return report;
  }

  tbc::view<ds::Option<ReportAgent>, tbc::lt::a> codexLifecycle(tbc::view<Payload&, tbc::lt::a> input, tbc::view<FixedText<96>&, tbc::lt::a> event, tbc::view<std::string_view, tbc::lt::a> database) {
    const auto name = input.event();

    if (input.subagent()) {
      if (name == "PreToolUse" || name == "PostToolUse") {
        return ReportAgent{.state = AgentReportState::continuing};
      }

      auto path = input.fields.text("transcript_path");
      const auto session = input.session();
      if (name == "SubagentStop" && input.running_subagents == 0 && !session.empty() && path.ends_with(".jsonl")) {
        path.remove_suffix(sizeof(".jsonl") - 1);
        if (path.size() > session.size() && path.ends_with(session) && path[path.size() - session.size() - 1] == '-') {
          return ReportAgent{.state = AgentReportState::released};
        }
      }

      return ds::none;
    }

    ReportAgent report{.session = sessionReference(input.session()), .session_file = database.size() <= 1024 ? database : "", .session_file_kind = AgentSessionFileKind::codex_state};

    if ((name == "Stop" || name == "Interrupt") && input.running_subagents != 0) {
      report.state = AgentReportState::waiting;
      backgroundEvent(event, input.running_subagents);
    } else if (name == "SessionStart") {
      report.state = input.fields.text("source") == "compact" ? AgentReportState::working : AgentReportState::ready;
    } else if (name == "UserPromptSubmit") {
      report.state = AgentReportState::working;
    } else if (name == "PreToolUse" || name == "PostToolUse" || name == "PermissionRequest") {
      report.state = name == "PermissionRequest" ? AgentReportState::blocked : AgentReportState::working;
      report.blocked_reason = name == "PermissionRequest" ? AgentBlockedReason::permission : AgentBlockedReason::none;
      toolEvent(event, input);
    } else if (name == "Stop") {
      report.state = AgentReportState::settling;
    } else if (name == "Interrupt") {
      report.state = AgentReportState::ready;
    } else if (name == "SessionEnd") {
      report.state = AgentReportState::exited;
      report.session = {};
    } else {
      return ds::none;
    }

    report.event = event.view();
    return report;
  }

  ds::Option<ReportAgent> piLifecycle(Payload& input) {
    const auto name = input.event();
    ReportAgent report{.session = sessionReference(input.session())};

    if (name == "session_start" || name == "agent_settled" || name == "ui_prompt_end" || name == "state_snapshot") {
      const bool idle = input.fields.boolean("idle").valueOr(name == "session_start" || name == "agent_settled");

      report.state = idle ? AgentReportState::ready : AgentReportState::working;
      if (input.fields.boolean("blocked").valueOr(false)) {
        report.state = AgentReportState::blocked;
        report.blocked_reason = AgentBlockedReason::question;
      }
    } else if (name == "agent_start") {
      report.state = AgentReportState::working;
    } else if (name == "ui_prompt_start") {
      report.state = AgentReportState::blocked;
      report.blocked_reason = AgentBlockedReason::question;
    } else if (name == "session_shutdown") {
      report.state = AgentReportState::exited;
      report.session = {};
    } else {
      return ds::none;
    }

    return report;
  }

  tbc::view<ds::Option<ReportAgent>, tbc::lt::a> openCodeLifecycle(tbc::view<Payload&, tbc::lt::a> input, tbc::view<FixedText<96>&, tbc::lt::a> event) {
    const auto name = input.event();
    const auto blocked = input.blockedReason();
    ReportAgent report{.session = sessionReference(input.session())};

    if (name == "tool.execute.before") {
      if (blocked != AgentBlockedReason::none) {
        return ds::none;
      }

      report.state = AgentReportState::working;
      toolEvent(event, input);
    } else if (name == "load" || name == "chat.message" || name == "session.status" || name == "permission.asked" || name == "question.asked" || name == "permission.replied" || name == "question.replied" || name == "question.rejected" || name == "state_snapshot") {
      report.state = input.fields.boolean("busy").valueOr(false) ? AgentReportState::working : AgentReportState::ready;
      if (blocked != AgentBlockedReason::none) {
        report.state = AgentReportState::blocked;
        report.blocked_reason = blocked;
        if (blocked == AgentBlockedReason::permission) {
          toolEvent(event, input);
        } else if (blocked == AgentBlockedReason::question) {
          questionEvent(event, input);
        }
      }
    } else if (name == "dispose") {
      report.state = AgentReportState::exited;
      report.session = {};
    } else {
      return ds::none;
    }

    report.event = event.view();
    return report;
  }

  tbc::view<ds::Option<ReportAgent>, tbc::lt::a> cursorLifecycle(tbc::view<Payload&, tbc::lt::a> input, tbc::view<FixedText<96>&, tbc::lt::a> event, tbc::view<std::string_view, tbc::lt::a> metadata) {
    const auto name = input.event();
    ReportAgent report{.session = sessionReference(input.session()), .session_file = metadata.size() <= 1024 ? metadata : "", .session_file_kind = AgentSessionFileKind::cursor_meta};

    if (name == "sessionStart" || name == "stop") {
      report.state = AgentReportState::ready;
    } else if (name == "beforeSubmitPrompt") {
      report.state = AgentReportState::working;
    } else if (input.toolEvent() != name) {
      report.state = AgentReportState::working;
      toolEvent(event, input);
    } else if (name == "sessionEnd") {
      report.state = AgentReportState::exited;
      report.session = {};
    } else {
      return ds::none;
    }

    report.event = event.view();
    return report;
  }

  ds::Option<AgentPlanStatus> planStatus(std::string_view text) noexcept {
    constexpr ds::Array names{"pending", "in_progress", "completed", "deleted"};
    const auto found = std::ranges::find(names, text);

    return found == names.end() ? ds::none : ds::Option{static_cast<AgentPlanStatus>(found - names.begin())};
  }

  void setPlan(tbc::view<Payload&, tbc::lt::a> input, tbc::view<Reports&, tbc::lt::a> reports, tbc::view<ReportAgentProgress&, tbc::lt::a> report) {
    const bool todo = input.fields.text("tool_name") == "TodoWrite";
    const auto items = input.tools.value(todo ? "todos" : "plan");
    if (!items || !items->encoded().starts_with('[')) {
      return;
    }

    ds::String<Memory> current{input.memory};
    ds::String<Memory> pending{input.memory};

    items->eachElement([&](JsonValue value) {
      if (!value.encoded().starts_with('{')) {
        return;
      }

      Object item{input.memory, value};
      const auto status = planStatus(item.stringField("status").valueOr("pending")).valueOr(AgentPlanStatus::pending);
      if (status == AgentPlanStatus::deleted) {
        return;
      }

      report.plan_total += report.plan_total < std::numeric_limits<std::uint16_t>::max();
      if (status == AgentPlanStatus::completed) {
        report.plan_done += report.plan_done < std::numeric_limits<std::uint16_t>::max();
      } else if (status == AgentPlanStatus::in_progress && current.empty()) {
        current.assign(item.stringField(todo ? "activeForm" : "step").valueOr(item.stringField(todo ? "content" : "step").valueOr("")));
      } else if (status == AgentPlanStatus::pending && pending.empty()) {
        pending.assign(item.stringField(todo ? "content" : "step").valueOr(""));
      }
    });

    report.plan_op = AgentPlanOp::set;
    displayText(reports.step, current.empty() ? std::string_view{pending} : std::string_view{current}, false);
    report.plan_text = reports.step.view();
  }

  void updatePlan(tbc::view<Payload&, tbc::lt::a> input, tbc::view<Reports&, tbc::lt::a> reports, tbc::view<ReportAgentProgress&, tbc::lt::a> report) {
    if (input.event() == "SessionStart") {
      report.plan_op = AgentPlanOp::set;
      return;
    }

    if (input.event() != "PostToolUse") {
      return;
    }

    const auto tool = input.fields.text("tool_name");
    if (tool == "TaskCreate") {
      if (const auto subject = input.tools.stringField("subject")) {
        report.plan_op = AgentPlanOp::add;
        displayText(reports.step, *subject, false);
        report.plan_text = reports.step.view();
      }
    } else if (tool == "TaskUpdate") {
      const auto text = input.tools.stringField("taskId");
      const auto status = planStatus(input.tools.stringField("status").valueOr(""));
      if (!text || !status) {
        return;
      }

      const auto identifier = unsignedDecimal<std::uint16_t>(*text);
      if (identifier && *identifier != 0) {
        report.plan_op = AgentPlanOp::mark;
        report.plan_index = *identifier - 1;
        report.plan_status = *status;
      }
    } else if (tool == "TodoWrite" || tool == "update_plan") {
      setPlan(input, reports, report);
    }
  }

  tbc::view<ds::Option<ReportAgentProgress>, tbc::lt::a> progressReport(tbc::view<Payload&, tbc::lt::a> input, tbc::view<Reports&, tbc::lt::a> reports) {
    if ((input.provider != AgentProvider::claude && input.provider != AgentProvider::codex) || input.subagent()) {
      return ds::none;
    }

    ReportAgentProgress report;
    const auto changed = input.provider == AgentProvider::claude ? input.fields.text("new_cwd") : std::string_view{};
    const auto cwd = changed.empty() ? input.fields.text("cwd") : changed;
    if (cwd.starts_with('/') && cwd.size() <= 4096) {
      report.cwd = cwd;
      if (const auto linked = reports.worktree.find(cwd)) {
        try {
          DisplayText16<200>::validate(linked->branch);
          report.work_tree_path = cwd.substr(0, linked->root_length);
          report.work_tree_branch = linked->branch;
        } catch (const EncodingError&) {
        }
      }
    }

    updatePlan(input, reports, report);
    if (input.event() == "Stop") {
      displayText(reports.message, input.fields.optionalText("last_assistant_message").valueOr(""), true);
      report.final_message = reports.message.view();
    }

    return report.cwd.empty() && report.plan_op == AgentPlanOp::none && report.final_message.empty() ? ds::none : ds::Option{report};
  }

  // The title an agent sets, on one line without control bytes, which the codec refuses in a title.
  ds::Option<ReportAgentTitle> titleReport(Payload& input, FixedText<96>& text) {
    ds::Option<std::string_view> title;

    if (input.provider == AgentProvider::claude) {
      if (input.event() == "SessionStart" && !input.fields.optionalText("agent_id").hasValue() && !input.fields.text("session_title").empty()) {
        title = input.fields.text("session_title");
      }
    } else if (input.provider == AgentProvider::pi) {
      if (input.event() == "session_info_changed") {
        title = input.fields.optionalText("name").valueOr("");
      } else if (input.event() == "session_start") {
        title = input.fields.optionalText("name");
      }
    } else if (input.provider == AgentProvider::opencode && input.event() == "session.updated") {
      title = input.fields.optionalText("title");
      if (title && defaultOpenCodeTitle(*title)) {
        title = "";
      }
    }

    if (!title) {
      return ds::none;
    }

    displayText(text, *title, false);
    return ReportAgentTitle{.title = text.view()};
  }

  template <EnvironmentLookup Environment>
  // The reports view the payload, the files and their own texts, all region `a`.
  void map(tbc::view<Payload&, tbc::lt::a> input, tbc::view<Reports&, tbc::lt::a> reports, tbc::view<SessionFiles&, tbc::lt::a> files, const Environment& environment) {
    TELAR_TRACE("hooks.mapReports");
    reports.command = commandReport(input);
    reports.title = titleReport(input, reports.title_text);
    reports.progress = progressReport(input, reports);
    switch (input.provider) {
    case AgentProvider::claude:
      reports.lifecycle = claudeLifecycle(input, reports.event);
      break;
    case AgentProvider::codex: {
      if (input.event() == "Stop" || input.event() == "Interrupt" || input.event() == "SubagentStop") {
        CodexSubagents children;

        children.read(input.fields.text("transcript_path"));
        input.running_subagents = children.countExcept(input.fields.optionalText("agent_id").valueOr(""));
      }

      const auto database = files.codex(environment);
      const bool has_home = !environment.lookup("CODEX_HOME").empty() || !environment.lookup("HOME").empty();

      reports.lifecycle = codexLifecycle(input, reports.event, has_home ? database : input.fields.text("state_database"));
      break;
    }
    case AgentProvider::pi:
      reports.lifecycle = piLifecycle(input);
      break;
    case AgentProvider::opencode:
      reports.lifecycle = openCodeLifecycle(input, reports.event);
      break;
    case AgentProvider::cursor:
      reports.lifecycle = cursorLifecycle(input, reports.event, files.cursor(input, environment));
      break;
    default:
      break;
    }
  }

  ds::Option<std::uint64_t> unsignedValue(std::string_view value) noexcept {
    return unsignedDecimal<std::uint64_t>(value);
  }

  template <EnvironmentLookup Environment>
  ds::Option<PaneTarget> paneTarget(const Environment& environment, AgentProvider provider) noexcept {
    const auto pane = unsignedValue(environment.lookup("TELAR_PANE_ID"));
    const auto generation = unsignedValue(environment.lookup("TELAR_PANE_GENERATION"));
    if (!pane || *pane == 0 || !generation) {
      return ds::none;
    }

    return PaneTarget{.pane_id = *pane, .generation = *generation, .provider = provider};
  }

  bool validWorktreeBranch(std::string_view branch) noexcept {
    if (branch.empty() || branch.size() > 200 || branch.front() == '-' || branch.front() == '.' || branch.contains("..")) {
      return false;
    }

    try {
      validateUtf8(branch);
    } catch (const EncodingError&) {
      return false;
    }

    return std::ranges::none_of(branch, [](unsigned char byte) {
      return byte <= ' ' || byte == 0x7f || byte == '~' || byte == '^' || byte == ':';
    });
  }

  template <EnvironmentLookup Environment>
  class Worktrees {
  public:
    explicit Worktrees(Memory& memory, const Environment& environment, std::string_view socket)
        : memory_(memory),
          environment_(environment),
          socket_(socket),
          output_(memory, maximum_output_bytes),
          root_(memory),
          branch_(memory),
          base_(memory),
          path_(memory) {}

    void answer(Object& input) {
      TELAR_TRACE("hooks.worktree");
      if (input.text("hook_event_name") == "WorktreeCreate") {
        create(input);
      } else {
        remove(input);
      }
    }

  private:
    std::string_view git(std::initializer_list<std::string_view> arguments, const char* failure) {
      if (std::ranges::any_of(arguments, [](std::string_view argument) {
            return argument.contains('\0');
          })) {
        throw std::runtime_error{failure};
      }

      Command command{memory_, Launch{.arguments = {arguments.begin(), arguments.size()}}, CommandPurpose::configured_helper};

      HardenedGit<Memory>::configure(command);
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{300};
      const bool mutation = std::ranges::find(arguments, "worktree") != arguments.end();
      if (mutation) {
        RetainedStream diagnostics{memory_, maximum_output_bytes};
        const auto status = output_.streamDiagnostics(command, deadline, [](std::span<const Byte>) {
          return true;
        },
            [&](std::span<const Byte> bytes) {
              diagnostics.append(bytes);
            });
        if (status != 0) {
          ds::Array<Byte, maximum_output_bytes> buffer;
          const auto kept = diagnostics.read(diagnostics.retainedOffset(), buffer.viewMut());

          if (diagnostics.retainedOffset() != 0) {
            std::fprintf(stderr, "(%llu earlier bytes of Git's output omitted)\n", static_cast<unsigned long long>(diagnostics.retainedOffset()));
          }

          std::fwrite(kept.data(), 1, kept.size(), stderr);
          throw std::runtime_error{failure};
        }

        return {};
      }

      if (output_.run(command, deadline) != 0) {
        throw std::runtime_error{failure};
      }

      return trimText(output_.text(), " \r\n");
    }

    void mainRoot(std::string_view directory) {
      auto common = git({"git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"}, "NotARepository");

      while (common.ends_with('/')) {
        common.remove_suffix(1);
      }

      if (!common.starts_with('/') || !common.ends_with("/.git")) {
        throw std::runtime_error{"NotARepository"};
      }

      root_.assign(common.substr(0, common.size() - 5));
    }

    void chooseBranch(std::string_view name) {
      branch_.assign(name);
      if (validWorktreeBranch(branch_)) {
        return;
      }

      branch_.resize(std::min<std::size_t>(branch_.size(), 200));
      for (auto& character : branch_.viewMut()) {
        const auto byte = static_cast<unsigned char>(character);
        const bool safe = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '/';
        if (!safe) {
          character = '-';
        }
      }

      branch_.assign(trimText(branch_, "-./"));
      if (!validWorktreeBranch(branch_)) {
        throw std::runtime_error{"InvalidWorktreeBranch"};
      }
    }

    void create(Object& input) {
      ds::Array<char, PATH_MAX> current;
      auto cwd = input.text("cwd");
      if (cwd.empty()) {
        if (::getcwd(current.dataMut(), current.size()) == nullptr) {
          throw SystemError{"Read working directory"};
        }

        cwd = current.data();
      }

      mainRoot(cwd);
      chooseBranch(input.text("name"));
      base_.assign(git({"git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"}, "NotARepository"));
      if (!validWorktreeBranch(base_)) {
        throw std::runtime_error{"InvalidWorktreeBranch"};
      }

      path_.clear();
      sessions::appendWorktreeCheckout(path_, root_, branch_);
      ds::String<Memory> reference{memory_, "refs/heads/"};

      reference.append(branch_);
      bool exists = true;

      try {
        git({"git", "-C", root_, "show-ref", "--verify", "--quiet", reference}, "branch unavailable");
      } catch (const std::exception&) {
        exists = false;
      }

      if (exists) {
        git({"git", "-C", root_, "worktree", "add", "--", path_, branch_}, "WorktreeAddFailed");
      } else {
        git({"git", "-C", root_, "worktree", "add", "-b", branch_, "--", path_, base_}, "WorktreeAddFailed");
      }

      try {
        registerWorktree();
      } catch (const std::exception& error) {
        std::fprintf(stderr, "telar hook: worktree created but not tracked: %s\n", error.what());
      }

      std::printf("%s\n", path_.data());
    }

    RuntimePaths<Memory> paths() {
      ServerOptions options;

      options.socket = socket_;
      return RuntimePaths{memory_, options, environment_};
    }

    void registerWorktree() {
      const auto pane = unsignedValue(environment_.lookup("TELAR_PANE_ID"));
      const auto workspace_text = environment_.lookup("TELAR_WORKSPACE_ID");
      if (!pane || workspace_text.empty()) {
        return;
      }

      const auto workspace = unsignedValue(workspace_text);
      if (!workspace || *workspace == 0) {
        throw std::runtime_error{"InvalidWorkspaceId"};
      }

      if (*pane == 0) {
        throw std::runtime_error{"InvalidPaneId"};
      }

      const auto target = paneTarget(environment_, AgentProvider::claude);
      if (!target || target->generation == 0) {
        throw std::runtime_error{missing_pane_context};
      }

      const auto resolved = paths();
      Session session{memory_, resolved.socket.data(), *target};

      session.template exchange<WorktreeRegistered>(RegisterWorktree{.source = *workspace, .created_by = target->pane_id, .path = path_, .branch = branch_, .base = base_});
    }

    void remove(Object& input) {
      path_.assign(input.text("worktree_path"));
      if (!path_.view().starts_with('/') || path_.view().contains('\0')) {
        throw std::runtime_error{"InvalidWorktreePath"};
      }

      mainRoot(path_);
      try {
        git({"git", "-C", root_, "worktree", "remove", "--", path_}, "git worktree remove failed");
      } catch (const std::exception&) {
        std::fprintf(stderr, "telar hook: kept %s; it has changes to review\n", path_.data());
        return;
      }

      // Only a checkout that is gone leaves the runtime's catalog; a kept one stays tracked.
      if (const auto pane = unsignedValue(environment_.lookup("TELAR_PANE_ID")); pane) {
        try {
          forgetWorktree();
        } catch (const std::exception&) {
        }
      }
    }

    void forgetWorktree() {
      const auto resolved = paths();
      RuntimeConnection connection{resolved.socket.data()};

      connection.receiveTimeout(30);
      ds::Vec<Byte, Memory> incoming{memory_};
      ds::Vec<Byte, Memory> decoded{memory_};

      incoming.resize(max_payload_size);
      decoded.resize(max_payload_size);
      ds::Array<Byte, 64> outgoing;
      std::uint64_t identity = 0;

      while (identity == 0) {
        randomBytes(&identity, sizeof(identity));
      }

      connection.send(RequestRuntimeState{.client_identity = identity, .interactive = false}, outgoing.viewMut());
      for (;;) {
        const auto frame = connection.receive(incoming.viewMut());
        if (frame.front() == static_cast<Byte>(ServerTag::workspace_list)) {
          DecodeStorage storage{decoded.viewMut()};
          const auto catalog = Codec::decode<WorkspaceList>(frame, storage);

          for (const auto& worktree : catalog.worktrees) {
            if (worktree.path == path_) {
              connection.send(ForgetWorktree{.request_id = 1, .worktree = worktree.worktree}, outgoing.viewMut());
              waitForgotten(connection, incoming.viewMut());
              return;
            }
          }

          return;
        }

        if (frame.front() == static_cast<Byte>(ServerTag::request_failed) || frame.front() == static_cast<Byte>(ServerTag::runtime_stopping)) {
          return;
        }
      }
    }

    static void waitForgotten(RuntimeConnection& connection, std::span<Byte> incoming) {
      for (;;) {
        const auto frame = connection.receive(incoming);
        if (frame.front() == static_cast<Byte>(ServerTag::request_completed) || frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
          return;
        }
      }
    }

    static constexpr std::size_t maximum_output_bytes = 64 * 1024;
    Memory& memory_;
    const Environment& environment_;
    std::string_view socket_;
    CommandOutput<Memory> output_;
    ds::String<Memory> root_;
    ds::String<Memory> branch_;
    ds::String<Memory> base_;
    ds::String<Memory> path_;
  };

  template <EnvironmentLookup Environment>
  Worktrees(Memory& memory, const Environment& environment, std::string_view socket) -> Worktrees<Environment>;

  template <EnvironmentLookup Environment>
  ds::Option<int> answerWorktree(Memory& memory, const Environment& environment, Object& fields, std::string_view socket) {
    try {
      for (const auto name : {"hook_event_name", "cwd", "name", "worktree_path"}) {
        fields.text(name);
      }

      const auto event = fields.text("hook_event_name");
      if (event == "WorktreeCreate" || event == "WorktreeRemove") {
        try {
          Worktrees{memory, environment, socket}.answer(fields);
          return 0;
        } catch (const std::exception& error) {
          std::fprintf(stderr, "telar hook: %.*s failed: %s\n", static_cast<int>(event.size()), event.data(), error.what());
          return 1;
        }
      }
    } catch (const std::exception&) {
    }

    return ds::none;
  }

}

namespace telar::runtime::cli {

  template <EnvironmentLookup Environment>
  int runHook(Memory& memory, const HookOptions& options, const Environment& environment) noexcept {
#if TELAR_DEBUG
    ds::Option<trace::Session<Memory>> tracing;

    try {
      const ds::String<Memory> path{memory, environment.lookup("TELAR_HOOK_TRACE")};
      if (!path.empty()) {
        tracing.emplace(memory, path.data());
      }
    } catch (const std::exception&) {
    }
#endif

    hooks::Input input{memory};
    int status = 0;

    try {
      input.read(STDIN_FILENO);
      validateUtf8(input.text());
      const auto parsed = JsonValue::parse(input.text());

      hooks::validateUnicodeEscapes(memory, input.text());
      hooks::Object fields{memory, parsed, true};
      const auto worktree_status = options.provider == AgentProvider::claude ? hooks::answerWorktree(memory, environment, fields, options.socket) : ds::none;

      status = worktree_status.valueOr(0);
      const auto target = hooks::paneTarget(environment, options.provider);
      if (!worktree_status && target) {
        hooks::Payload payload{memory, options.provider, std::move(fields)};
        hooks::Reports reports;
        hooks::SessionFiles files;

        hooks::map(payload, reports, files, environment);
        if (!reports.empty()) {
          ServerOptions server;

          server.socket = options.socket;
          const RuntimePaths paths{memory, server, environment};
          hooks::Session session{memory, paths.socket.data(), *target};

          if (reports.progress) {
            session.report(*reports.progress);
          }

          if (reports.lifecycle) {
            session.report(*reports.lifecycle);
          }

          if (reports.title) {
            session.report(*reports.title);
          }

          if (reports.command) {
            session.report(*reports.command);
          }

          if (input.limited()) {
            session.reportLimit(input.received(), input.maximum_bytes);
          }
        }
      }
    } catch (const std::exception&) {
    }

    if (input.limited()) {
      std::fprintf(stderr, "telar: Limit reached: hooks.max_input_bytes: %llu bytes; limit %zu\n", static_cast<unsigned long long>(input.received()), input.maximum_bytes);
    }

    return status;
  }

  template int runHook<ProcessEnvironment>(Memory& memory, const HookOptions& options, const ProcessEnvironment& environment) noexcept;

}

namespace telar::runtime::cli::hooks {

  template void map<ProcessEnvironment>(tbc::view<Payload&, tbc::lt::a> input, tbc::view<Reports&, tbc::lt::a> reports, tbc::view<SessionFiles&, tbc::lt::a> files, const ProcessEnvironment& environment);

  Input::Input(Memory& memory)
      : text_(memory) {}

  void Input::read(int descriptor) {
    TELAR_TRACE("hooks.readInput");
    ds::Array<char, 4096> buffer;

    for (;;) {
      const auto count = ::read(descriptor, buffer.dataMut(), buffer.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count < 0) {
        throw SystemError{"Read hook input"};
      }

      if (count == 0) {
        break;
      }

      received_ += static_cast<std::size_t>(count);
      text_.append(std::string_view{buffer.data(), std::min(static_cast<std::size_t>(count), maximum_bytes - text_.size())});
    }

    if (limited()) {
      keepWholeMembers();
    }
  }

  bool Input::limited() const noexcept {
    return received_ > maximum_bytes;
  }

  std::uint64_t Input::received() const noexcept {
    return received_;
  }

  std::string_view Input::text() const noexcept {
    return text_;
  }

  void Input::keepWholeMembers() {
    const auto opening = text_.view().find_first_not_of(" \r\n\t");
    if (opening == std::string_view::npos || text_[opening] != '{') {
      text_.assign("{}");
      return;
    }

    std::size_t depth = 0;
    std::size_t complete = 0;
    std::size_t member_start = opening + 1;
    ds::String<Memory> candidate{text_.memory()};
    bool quoted = false;
    bool escaped = false;

    for (std::size_t index = 0; index < text_.size(); ++index) {
      const char byte = text_[index];

      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (byte == '\\') {
          escaped = true;
        } else if (byte == '"') {
          quoted = false;
        }

        continue;
      }

      if (byte == '"') {
        quoted = true;
      } else if (byte == '{' || byte == '[') {
        ++depth;
      } else if (byte == '}' || byte == ']') {
        if (depth == 0) {
          break;
        }

        if (--depth == 0) {
          if (completeMember(member_start, index, candidate)) {
            complete = index;
          }

          break;
        }
      } else if (byte == ',' && depth == 1) {
        if (!completeMember(member_start, index, candidate)) {
          break;
        }

        complete = index;
        member_start = index + 1;
      }
    }

    if (complete == 0) {
      text_.assign("{}");
    } else {
      text_.resize(complete);
      text_.push('}');
    }
  }

  bool Input::completeMember(std::size_t start, std::size_t end, ds::String<Memory>& candidate) {
    if (std::string_view{text_.data() + start, end - start}.find_first_not_of(" \r\n\t") == std::string_view::npos) {
      return false;
    }

    candidate.assign("{");
    candidate.append(std::string_view{text_.data() + start, end - start});
    candidate.append("}");
    try {
      JsonValue::parse(candidate);
      validateUnicodeEscapes(candidate.memory(), candidate);
      return true;
    } catch (const JsonError&) {
      return false;
    }
  }

  template <EnvironmentLookup Environment>
  std::string_view SessionFiles::codex(const Environment& environment) noexcept {
    try {
      const auto override = environment.lookup("CODEX_HOME");
      const auto home = override.empty() ? join(environment.lookup("HOME"), ".codex", root_.viewMut()) : copy(override, root_.viewMut());
      if (!home) {
        return {};
      }

      DirectoryStream directory{FileDescriptor{::open(home->data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      ds::Option<std::uint32_t> best;

      while (const auto* entry = directory.next()) {
        const std::string_view name{entry->d_name, std::strlen(entry->d_name)};
        if (entry->d_type != DT_REG || !name.starts_with("state_") || !name.ends_with(".sqlite")) {
          continue;
        }

        const auto number = name.substr(6, name.size() - 13);
        const auto version = unsignedDecimal<std::uint32_t>(number);
        if (version && (!best || *version > *best)) {
          best = *version;
        }
      }

      if (!best) {
        return {};
      }

      ds::Array<char, 32> filename;
      const auto length = std::snprintf(filename.dataMut(), filename.size(), "state_%u.sqlite", *best);

      return join(*home, {filename.data(), static_cast<std::size_t>(length)}, path_.viewMut()).valueOr("");
    } catch (const std::exception&) {
      return {};
    }
  }

  template <EnvironmentLookup Environment>
  std::string_view SessionFiles::cursor(Payload& input, const Environment& environment) noexcept {
    try {
      if (input.event() != "sessionStart" && input.event() != "beforeSubmitPrompt") {
        return {};
      }

      const auto chat = input.session();
      if (chat.empty() || chat.size() > 64 || !std::ranges::all_of(chat, [](unsigned char byte) {
            return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-';
          })) {
        return {};
      }

      const auto root = cursorRoot(environment);
      if (!root) {
        return {};
      }

      const auto digest = input.workspace().empty() ? ds::none : md5(input.workspace());
      if (digest) {
        ds::Array<char, 2 * MD5_DIGEST_LENGTH> encoded;
        if (const auto path = cursorPath(*root, encodeLowerHex(*digest, encoded.viewMut()), chat)) {
          return *path;
        }
      }

      const auto chats = join(*root, "chats", path_.viewMut());
      if (!chats) {
        return {};
      }

      DirectoryStream directory{FileDescriptor{::open(chats->data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      constexpr std::size_t maximum_directories = 4096;

      for (std::size_t count = 0; count < maximum_directories; ++count) {
        const auto* entry = directory.next();
        if (entry == nullptr) {
          break;
        }

        if (entry->d_type == DT_DIR && std::strlen(entry->d_name) == 32) {
          if (const auto path = cursorPath(*root, {entry->d_name, std::strlen(entry->d_name)}, chat)) {
            return *path;
          }
        }
      }
    } catch (const std::exception&) {
    }

    return {};
  }

  template <EnvironmentLookup Environment>
  ds::Option<std::string_view> SessionFiles::cursorRoot(const Environment& environment) {
    if (const auto configured = environment.lookup("CURSOR_CONFIG_DIR"); !configured.empty()) {
      return copy(configured, root_.viewMut());
    }

    if (const auto xdg = environment.lookup("XDG_CONFIG_HOME"); !xdg.empty()) {
      return join(xdg, "cursor", root_.viewMut());
    }

    return join(environment.lookup("HOME"), ".cursor", root_.viewMut());
  }

  ds::Option<std::string_view> SessionFiles::cursorPath(std::string_view root, std::string_view digest, std::string_view chat) {
    const auto length = std::snprintf(path_.dataMut(), path_.size(), "%.*s/chats/%.*s/%.*s/meta.json", static_cast<int>(root.size()), root.data(), static_cast<int>(digest.size()), digest.data(), static_cast<int>(chat.size()), chat.data());
    if (length < 0 || static_cast<std::size_t>(length) >= path_.size()) {
      return ds::none;
    }

    struct stat status;

    return ::lstat(path_.data(), &status) == 0 && S_ISREG(status.st_mode) ? ds::Option{std::string_view{path_.data(), static_cast<std::size_t>(length)}} : ds::none;
  }

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> SessionFiles::copy(std::string_view value, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    if (value.empty() || value.size() >= buffer.size() || value.contains('\0')) {
      return ds::none;
    }

    std::memcpy(buffer.data(), value.data(), value.size());
    buffer[value.size()] = '\0';
    return std::string_view{buffer.data(), value.size()};
  }

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> SessionFiles::join(std::string_view root, std::string_view suffix, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    return root.empty() ? ds::none : GitFiles::join(root, suffix, buffer);
  }

}
