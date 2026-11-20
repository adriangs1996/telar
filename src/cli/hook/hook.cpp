module;
#include "telar_platform/trace_macro.hpp"

module telar.cli.hook;
import telar.platform.sha256;
import telar.sys.posix;
import telar.cli.command_limit;
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
import telar.base.text;
import telar.base.text.json;

namespace telar::runtime::cli::hooks {

  // The bytes the runtime's reports carry of a session file's path and of a working directory.
  constexpr std::size_t session_file_bytes = 1024;
  constexpr std::size_t cwd_bytes = 4096;
  // Cursor names a workspace's folder after the hex MD5 of its path.
  constexpr std::size_t digest_hex_bytes = std::size_t{2} * MD5_DIGEST_LENGTH;
  constexpr int directory_flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC; // NOLINT(bugprone-signed-bitwise): POSIX defines the open flags as int.

  namespace {

    // A tool call keeps Claude working; a question or a plan it presents blocks it on the user.
    void claudeToolUse(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event, ReportAgent& report) {
      toolEvent(event, input);
      report.state = AgentReportState::working;
      const auto tool = input.fields().text("tool_name");
      if (input.event() != "PreToolUse" || (tool != "AskUserQuestion" && tool != "ExitPlanMode")) {
        return;
      }

      report.state = AgentReportState::blocked;
      report.blocked_reason = tool == "AskUserQuestion" ? AgentBlockedReason::question : AgentBlockedReason::plan;
      if (tool == "AskUserQuestion") {
        questionEvent(event, input);
      }
    }

    // Whether the notification is one of Claude's states: idle, or blocked on the user.
    bool claudeNotification(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event, ReportAgent& report) {
      const auto notification = input.fields().text("notification_type");
      if (notification == "idle_prompt") {
        report.state = AgentReportState::idle;
        return true;
      }

      if (notification != "permission_prompt" && notification != "elicitation_dialog" && notification != "elicitation_url_dialog" && notification != "agent_needs_input") {
        return false;
      }

      report.state = AgentReportState::blocked;
      report.blocked_reason = notification == "permission_prompt" ? AgentBlockedReason::permission : AgentBlockedReason::question;
      eventLine(event, input.fields().text("message"));
      return true;
    }

    // A Codex subagent's tool calls keep its parent working, and the last one to stop releases it.
    ds::Option<ReportAgent> codexSubagent(const Payload& input) {
      const auto name = input.event();
      if (name == "PreToolUse" || name == "PostToolUse") {
        return ReportAgent{.state = AgentReportState::continuing};
      }

      auto path = input.fields().text("transcript_path");
      const auto session = input.session();
      if (name == "SubagentStop" && input.runningSubagents() == 0 && !session.empty() && path.ends_with(".jsonl")) {
        path.remove_suffix(sizeof(".jsonl") - 1);
        if (path.ends_with(session) && path.substr(0, path.size() - session.size()).ends_with('-')) {
          return ReportAgent{.state = AgentReportState::released};
        }
      }

      return ds::none;
    }

  }

  tbc::val_a<ds::Option<ReportAgent>> claudeLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event) {
    const auto name = input.event();

    if (input.subagent()) {
      return name == "PreToolUse" || name == "PostToolUse" ? ds::Option{ReportAgent{.state = AgentReportState::continuing}} : ds::none;
    }

    const auto file = input.fields().text("transcript_path");
    ReportAgent report{.session = sessionReference(input.session()), .session_file = file.size() <= session_file_bytes ? file : ""};

    if (name == "SessionStart") {
      report.state = AgentReportState::ready;
    } else if (name == "UserPromptSubmit") {
      report.state = AgentReportState::working;
    } else if (name == "PreToolUse" || name == "PostToolUse") {
      claudeToolUse(input, event, report);
    } else if (name == "Stop") {
      report.state = input.runningSubagents() == 0 ? AgentReportState::ready : AgentReportState::waiting;
      if (input.runningSubagents() == 0) {
        eventLine(event, input.fields().text("last_assistant_message"));
      } else {
        backgroundEvent(event, input.runningSubagents());
      }
    } else if (name == "SessionEnd") {
      report.state = AgentReportState::exited;
      report.session = {};
    } else if (name == "Notification") {
      if (!claudeNotification(input, event, report)) {
        return ds::none;
      }
    } else {
      return ds::none;
    }

    report.event = event.view();
    return report;
  }

  tbc::val_a<ds::Option<ReportAgent>> codexLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event, tbc::val_a<std::string_view> database) {
    const auto name = input.event();

    if (input.subagent()) {
      return codexSubagent(input);
    }

    ReportAgent report{.session = sessionReference(input.session()), .session_file = database.size() <= session_file_bytes ? database : "", .session_file_kind = AgentSessionFileKind::codex_state};

    if ((name == "Stop" || name == "Interrupt") && input.runningSubagents() != 0) {
      report.state = AgentReportState::waiting;
      backgroundEvent(event, input.runningSubagents());
    } else if (name == "SessionStart") {
      report.state = input.fields().text("source") == "compact" ? AgentReportState::working : AgentReportState::ready;
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

  tbc::val_a<ds::Option<ReportAgent>> piLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event) {
    const auto name = input.event();
    ReportAgent report{.session = sessionReference(input.session())};

    if (name == "session_start" || name == "agent_settled" || name == "ui_prompt_end" || name == "state_snapshot" || name == "tool_execution_start" || name == "tool_execution_end") {
      const bool idle = input.fields().boolean("idle").valueOr(name == "session_start" || name == "agent_settled");

      report.state = idle ? AgentReportState::ready : AgentReportState::working;
      if (input.fields().boolean("blocked").valueOr(false)) {
        report.state = AgentReportState::blocked;
        report.blocked_reason = AgentBlockedReason::question;
      } else if (!idle) {
        // Every report of a running agent carries the tool it last started, so the line outlives the call.
        toolEvent(event, input);
      } else if (name == "agent_settled") {
        eventLine(event, input.fields().text("last_assistant_message"));
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

    report.event = event.view();
    return report;
  }

  tbc::val_a<ds::Option<ReportAgent>> openCodeLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event) {
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
      report.state = input.fields().boolean("busy").valueOr(false) ? AgentReportState::working : AgentReportState::ready;
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

  tbc::val_a<ds::Option<ReportAgent>> cursorLifecycle(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> event, tbc::val_a<std::string_view> metadata) {
    const auto name = input.event();
    ReportAgent report{.session = sessionReference(input.session()), .session_file = metadata.size() <= session_file_bytes ? metadata : "", .session_file_kind = AgentSessionFileKind::cursor_meta};

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

  namespace {

    ds::Option<AgentPlanStatus> planStatus(std::string_view text) noexcept {
      constexpr ds::Array names{"pending", "in_progress", "completed", "deleted"};
      const auto* const found = std::ranges::find(names, text);

      return found == names.end() ? ds::none : ds::Option{static_cast<AgentPlanStatus>(found - names.begin())};
    }

    void setPlan(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> step, tbc::mut_a<ReportAgentProgress> report) {
      const bool todo = input.fields().text("tool_name") == "TodoWrite";
      const auto items = input.tools().value(todo ? "todos" : "plan");
      if (!items || !items->encoded().starts_with('[')) {
        return;
      }

      ds::String<Memory> current{input.memory()};
      ds::String<Memory> pending{input.memory()};

      items->eachElement([&](JsonValue value) {
        if (!value.encoded().starts_with('{')) {
          return;
        }

        const Object item{input.memory(), value};
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
      displayText(step, current.empty() ? std::string_view{pending} : std::string_view{current}, false);
      report.plan_text = step.view();
    }

    void updatePlan(tbc::ref_a<Payload> input, tbc::mut_a<FixedText<display_line_bytes>> step, tbc::mut_a<ReportAgentProgress> report) {
      if (input.event() == "SessionStart") {
        report.plan_op = AgentPlanOp::set;
        return;
      }

      if (input.event() != "PostToolUse") {
        return;
      }

      const auto tool = input.fields().text("tool_name");
      if (tool == "TaskCreate") {
        if (const auto subject = input.tools().stringField("subject")) {
          report.plan_op = AgentPlanOp::add;
          displayText(step, *subject, false);
          report.plan_text = step.view();
        }
      } else if (tool == "TaskUpdate") {
        const auto text = input.tools().stringField("taskId");
        const auto status = planStatus(input.tools().stringField("status").valueOr(""));
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
        setPlan(input, step, report);
      }
    }

  }

  tbc::val_a<ds::Option<ReportAgentProgress>> progressReport(tbc::ref_a<Payload> input, tbc::mut_a<ReportTexts> texts) {
    const bool from_pi = input.provider() == AgentProvider::pi;
    if ((input.provider() != AgentProvider::claude && input.provider() != AgentProvider::codex && !from_pi) || input.subagent()) {
      return ds::none;
    }

    ReportAgentProgress report;
    const auto changed = input.provider() == AgentProvider::claude ? input.fields().text("new_cwd") : std::string_view{};
    const auto reported = changed.empty() ? input.fields().text("cwd") : changed;
    // Pi reports only the final message.
    const auto cwd = from_pi ? std::string_view{} : reported;

    updatePlan(input, texts.step, report);
    if (input.event() == (from_pi ? "agent_settled" : "Stop")) {
      displayText(texts.message, input.fields().optionalText("last_assistant_message").valueOr(""), true);
      report.final_message = texts.message.view();
    }

    // Last: the worktree it names is viewed once the texts are written.
    if (cwd.starts_with('/') && cwd.size() <= cwd_bytes) {
      report.cwd = cwd;
      if (const auto linked = texts.worktree.find(cwd)) {
        try {
          DisplayText16<sessions::branch_bytes>::validate(linked->branch);
          report.work_tree_path = cwd.substr(0, linked->root_length);
          report.work_tree_branch = linked->branch;
        } catch (const EncodingError&) { // NOLINT(bugprone-empty-catch): a branch the codec refuses leaves the worktree out of the report.
        }
      }
    }

    return report.cwd.empty() && report.plan_op == AgentPlanOp::none && report.final_message.empty() ? ds::none : ds::Option{report};
  }

  // The title an agent sets, on one line without control bytes, which the codec refuses in a title.
  tbc::val_a<ds::Option<ReportAgentTitle>> titleReport(const Payload& input, tbc::mut_a<FixedText<display_line_bytes>> text) {
    ds::Option<std::string_view> title;

    if (input.provider() == AgentProvider::claude) {
      if (input.event() == "SessionStart" && !input.fields().optionalText("agent_id").hasValue() && !input.fields().text("session_title").empty()) {
        title = input.fields().text("session_title");
      }
    } else if (input.provider() == AgentProvider::pi) {
      if (input.event() == "session_info_changed") {
        title = input.fields().optionalText("name").valueOr("");
      } else if (input.event() == "session_start") {
        title = input.fields().optionalText("name");
      }
    } else if (input.provider() == AgentProvider::opencode && input.event() == "session.updated") {
      title = input.fields().optionalText("title");
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
  void map(tbc::mut_a<Payload> input, tbc::mut_a<Reports> reports, tbc::mut_a<ReportTexts> texts, tbc::mut_a<SessionFiles> files, const Environment& environment) {
    TELAR_TRACE("hooks.mapReports");
    reports.command = commandReport(input);
    reports.title = titleReport(input, texts.title_text);
    reports.progress = progressReport(input, texts);
    switch (input.provider()) {
    case AgentProvider::claude:
      reports.lifecycle = claudeLifecycle(input, texts.event);
      break;
    case AgentProvider::codex: {
      if (input.event() == "Stop" || input.event() == "Interrupt" || input.event() == "SubagentStop") {
        CodexSubagents children;

        children.read(input.fields().text("transcript_path"));
        input.setRunningSubagents(children.countExcept(input.fields().optionalText("agent_id").valueOr("")));
      }

      const auto database = files.codex(environment);
      const bool has_home = !environment.lookup("CODEX_HOME").empty() || !environment.lookup("HOME").empty();

      reports.lifecycle = codexLifecycle(input, texts.event, has_home ? database : input.fields().text("state_database"));
      break;
    }
    case AgentProvider::pi:
      reports.lifecycle = piLifecycle(input, texts.event);
      break;
    case AgentProvider::opencode:
      reports.lifecycle = openCodeLifecycle(input, texts.event);
      break;
    case AgentProvider::cursor:
      reports.lifecycle = cursorLifecycle(input, texts.event, files.cursor(input, environment));
      break;
    // Unknown and custom providers report no lifecycle.
    case AgentProvider::unknown:
    case AgentProvider::last_custom:
    default: // NOLINT(clang-diagnostic-covered-switch-default): custom providers take the values between the named ones.
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
    if (branch.empty() || branch.size() > sessions::branch_bytes || branch.front() == '-' || branch.front() == '.' || branch.contains("..")) {
      return false;
    }

    try {
      validateUtf8(branch);
    } catch (const EncodingError&) {
      return false;
    }

    constexpr unsigned char delete_byte = 0x7f;

    return std::ranges::none_of(branch, [](unsigned char byte) {
      return byte <= ' ' || byte == delete_byte || byte == '~' || byte == '^' || byte == ':';
    });
  }

  template <EnvironmentLookup Environment>
  class Worktrees {
  public:
    explicit Worktrees(Memory& memory [[clang::lifetimebound]], const Environment& environment [[clang::lifetimebound]], std::string_view socket [[clang::lifetimebound]])
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
          ds::Array<Byte, maximum_output_bytes> buffer{};
          const auto kept = diagnostics.read(diagnostics.retainedOffset(), buffer.viewMut());

          if (diagnostics.retainedOffset() != 0) {
            writeFormatted(STDERR_FILENO, "({} earlier bytes of Git's output omitted)\n", diagnostics.retainedOffset());
          }

          writeBytes(STDERR_FILENO, kept);
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

      constexpr std::string_view git_directory = "/.git";
      if (!common.starts_with('/') || !common.ends_with(git_directory)) {
        throw std::runtime_error{"NotARepository"};
      }

      common.remove_suffix(git_directory.size());
      root_.assign(common);
    }

    void chooseBranch(std::string_view name) {
      branch_.assign(name);
      if (validWorktreeBranch(branch_)) {
        return;
      }

      branch_.resize(std::min(branch_.size(), sessions::branch_bytes));
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
      ds::Array<char, PATH_MAX> current{};
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
        writeFormatted(STDERR_FILENO, "telar hook: worktree created but not tracked: {}\n", error.what());
      }

      writeFormatted(STDOUT_FILENO, "{}\n", path_.view());
    }

    RuntimePaths<Memory> paths() {
      ServerOptions options;

      options.socket = socket_;
      return RuntimePaths<Memory>{memory_, options, environment_};
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
        writeFormatted(STDERR_FILENO, "telar hook: kept {}; it has changes to review\n", path_.view());
        return;
      }

      // Only a checkout that is gone leaves the runtime's catalog; a kept one stays tracked.
      if (const auto pane = unsignedValue(environment_.lookup("TELAR_PANE_ID")); pane) {
        try {
          forgetWorktree();
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): the checkout is already gone; forgetting it is best effort.
        }
      }
    }

    void forgetWorktree() {
      const auto resolved = paths();
      RuntimeConnection connection{resolved.socket.data()};

      connection.receiveTimeout(forget_timeout_seconds);
      ds::Vec<Byte, Memory> incoming{memory_};
      ds::Vec<Byte, Memory> decoded{memory_};

      incoming.resize(max_payload_size);
      decoded.resize(max_payload_size);
      ds::Array<Byte, request_bytes> outgoing{};
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

          if (const auto worktree = listedWorktree(catalog)) {
            connection.send(ForgetWorktree{.request_id = 1, .worktree = *worktree}, outgoing.viewMut());
            waitForgotten(connection, incoming.viewMut());
          }

          return;
        }

        if (frame.front() == static_cast<Byte>(ServerTag::request_failed) || frame.front() == static_cast<Byte>(ServerTag::runtime_stopping)) {
          return;
        }
      }
    }

    // The runtime's identity of the worktree at path_, when it lists one.
    [[nodiscard]] ds::Option<std::uint64_t> listedWorktree(const WorkspaceList& catalog) const {
      for (const auto& worktree : catalog.worktrees) {
        if (worktree.path == path_) {
          return worktree.worktree;
        }
      }

      return ds::none;
    }

    static void waitForgotten(RuntimeConnection& connection, std::span<Byte> incoming) {
      for (;;) {
        const auto frame = connection.receive(incoming);
        if (frame.front() == static_cast<Byte>(ServerTag::request_completed) || frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
          return;
        }
      }
    }

    static constexpr std::size_t maximum_output_bytes = std::size_t{64} * 1024;
    static constexpr unsigned forget_timeout_seconds = 30;
    // Bytes of one encoded request to the runtime.
    static constexpr std::size_t request_bytes = 64;
    // Worktrees answers one hook inside the call that builds it, and is never copied or assigned.
    Memory& memory_;                 // NOLINT(cppcoreguidelines-avoid-const-or-ref-data-members)
    const Environment& environment_; // NOLINT(cppcoreguidelines-avoid-const-or-ref-data-members)
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
      for (const auto* const name : {"hook_event_name", "cwd", "name", "worktree_path"}) {
        static_cast<void>(fields.text(name));
      }

      const auto event = fields.text("hook_event_name");
      if (event == "WorktreeCreate" || event == "WorktreeRemove") {
        try {
          Worktrees{memory, environment, socket}.answer(fields);
          return 0;
        } catch (const std::exception& error) {
          writeFormatted(STDERR_FILENO, "telar hook: {} failed: {}\n", event, error.what());
          return 1;
        }
      }

      return ds::none;
    } catch (const std::exception&) {
      // A payload whose worktree fields are not unique strings asks for no worktree.
      return ds::none;
    }
  }

  void sendReports(Session& session, const Reports& reports, const Input& input) {
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
      session.reportLimit(input.received(), Input::maximum_bytes);
    }
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
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): tracing is a debugging aid; the hook runs without it.
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
        hooks::ReportTexts texts;
        hooks::SessionFiles files;

        hooks::map(payload, reports, texts, files, environment);
        if (!reports.empty()) {
          ServerOptions server;

          server.socket = options.socket;
          const RuntimePaths<Memory> paths{memory, server, environment};
          hooks::Session session{memory, paths.socket.data(), *target};

          hooks::sendReports(session, reports, input);
        }
      }
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a hook never fails the agent it observes.
    }

    if (input.limited()) {
      try {
        writeFormatted(STDERR_FILENO, "telar: Limit reached: hooks.max_input_bytes: {} bytes; limit {}\n", input.received(), hooks::Input::maximum_bytes);
      } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): with stderr gone the notice has nowhere to go, and a hook never fails its agent.
      }
    }

    return status;
  }

  template int runHook<ProcessEnvironment>(Memory& memory, const HookOptions& options, const ProcessEnvironment& environment) noexcept;

}

namespace telar::runtime::cli::hooks {

  template void map<ProcessEnvironment>(tbc::mut_a<Payload> input, tbc::mut_a<Reports> reports, tbc::mut_a<ReportTexts> texts, tbc::mut_a<SessionFiles> files, const ProcessEnvironment& environment);

  Input::Input(Memory& memory)
      : text_(memory) {}

  void Input::read(int descriptor) {
    TELAR_TRACE("hooks.readInput");
    constexpr std::size_t chunk_bytes = 4096;
    ds::Array<char, chunk_bytes> buffer{};

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

  namespace {

    // Follows a JSON text byte by byte: whether each byte lies in a string literal, its quotes included.
    class StringLiteral {
    public:
      bool contains(char byte) noexcept {
        if (!quoted_) {
          quoted_ = byte == '"';
          return quoted_;
        }

        if (escaped_) {
          escaped_ = false;
        } else if (byte == '\\') {
          escaped_ = true;
        } else if (byte == '"') {
          quoted_ = false;
        }

        return true;
      }

    private:
      bool quoted_ = false;
      bool escaped_ = false;
    };

    // Whether one member, braced alone, parses as a JSON object.
    bool completeMember(std::string_view member, ds::String<Memory>& candidate) {
      if (member.find_first_not_of(" \r\n\t") == std::string_view::npos) {
        return false;
      }

      candidate.assign("{");
      candidate.append(member);
      candidate.append("}");
      try {
        JsonValue::parse(candidate);
        validateUnicodeEscapes(candidate.memory(), candidate);
        return true;
      } catch (const JsonError&) {
        return false;
      }
    }

    // Where the members of the object opening at `opening` stop parsing whole, or 0 when the
    // first one does not.
    std::size_t wholeMembersEnd(std::string_view text, std::size_t opening, ds::String<Memory>& candidate) {
      std::size_t depth = 0;
      std::size_t complete = 0;
      std::size_t member_start = opening + 1;
      std::size_t next = 0;
      StringLiteral literal;

      for (const char byte : text) {
        const auto index = next++;

        if (literal.contains(byte)) {
          continue;
        }

        if (byte == '{' || byte == '[') {
          ++depth;
        } else if (byte == '}' || byte == ']') {
          if (depth == 0) {
            break;
          }

          if (--depth == 0) {
            return completeMember(text.substr(member_start, index - member_start), candidate) ? index : complete;
          }
        } else if (byte == ',' && depth == 1) {
          if (!completeMember(text.substr(member_start, index - member_start), candidate)) {
            break;
          }

          complete = index;
          member_start = index + 1;
        }
      }

      return complete;
    }

  }

  void Input::keepWholeMembers() {
    const auto text = text_.view();
    const auto opening = text.find_first_not_of(" \r\n\t");
    ds::String<Memory> candidate{text_.memory()};
    const auto complete = opening == std::string_view::npos || !text.substr(opening).starts_with('{') ? 0 : wholeMembersEnd(text, opening, candidate);

    if (complete == 0) {
      text_.assign("{}");
    } else {
      text_.resize(complete);
      text_.push('}');
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

      DirectoryStream directory{FileDescriptor{::open(home->data(), directory_flags)}}; // NOLINT(cppcoreguidelines-pro-type-vararg): POSIX declares open variadic; a directory takes no mode.
      ds::Option<std::uint32_t> best;

      while (const auto* entry = directory.next()) {
        const std::string_view name{std::data(entry->d_name)};
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

      ds::Array<char, sizeof("state_4294967295.sqlite")> filename{};
      const auto written = std::format_to_n(filename.dataMut(), static_cast<std::ptrdiff_t>(filename.size()), "state_{}.sqlite", *best);

      return join(*home, {filename.data(), static_cast<std::size_t>(written.size)}, path_.viewMut()).valueOr("");
    } catch (const std::exception&) {
      return {};
    }
  }

  template <EnvironmentLookup Environment>
  std::string_view SessionFiles::cursor(const Payload& input, const Environment& environment) noexcept {
    try {
      if (input.event() != "sessionStart" && input.event() != "beforeSubmitPrompt") {
        return {};
      }

      const auto chat = input.session();
      constexpr std::size_t chat_bytes = 64;
      if (chat.empty() || chat.size() > chat_bytes || !std::ranges::all_of(chat, [](unsigned char byte) {
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
        ds::Array<char, digest_hex_bytes> encoded{};
        if (const auto path = cursorPath(*root, encodeLowerHex(*digest, encoded.viewMut()), chat)) {
          return *path;
        }
      }

      if (const auto path = cursorChat(*root, chat)) {
        return *path;
      }
    } catch (const std::exception&) {
      return {};
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

  // Looks for the chat under every workspace digest Cursor keeps in its chats directory.
  ds::Option<std::string_view> SessionFiles::cursorChat(std::string_view root, std::string_view chat) {
    const auto chats = join(root, "chats", path_.viewMut());
    if (!chats) {
      return ds::none;
    }

    DirectoryStream directory{FileDescriptor{::open(chats->data(), directory_flags)}}; // NOLINT(cppcoreguidelines-pro-type-vararg): POSIX declares open variadic; a directory takes no mode.
    constexpr std::size_t maximum_directories = 4096;

    for (std::size_t count = 0; count < maximum_directories; ++count) {
      const auto* entry = directory.next();
      if (entry == nullptr) {
        break;
      }

      const std::string_view name{std::data(entry->d_name)};
      if (entry->d_type == DT_DIR && name.size() == digest_hex_bytes) {
        if (const auto path = cursorPath(root, name, chat)) {
          return path;
        }
      }
    }

    return ds::none;
  }

  ds::Option<std::string_view> SessionFiles::cursorPath(std::string_view root, std::string_view digest, std::string_view chat) {
    // One byte stays for the terminator lstat needs.
    const auto written = std::format_to_n(path_.dataMut(), static_cast<std::ptrdiff_t>(path_.size() - 1), "{}/chats/{}/{}/meta.json", root, digest, chat);
    const auto length = static_cast<std::size_t>(written.size);
    if (length >= path_.size()) {
      return ds::none;
    }

    path_.atMut(length) = '\0';
    struct stat status{};

    return ::lstat(path_.data(), &status) == 0 && S_ISREG(status.st_mode) ? ds::Option{std::string_view{path_.data(), length}} : ds::none;
  }

  tbc::val_a<ds::Option<std::string_view>> SessionFiles::copy(std::string_view value, tbc::val_a<std::span<char>> buffer) noexcept {
    if (value.empty() || value.size() >= buffer.size() || value.contains('\0')) {
      return ds::none;
    }

    const auto end = std::ranges::copy(value, buffer.begin()).out;

    *end = '\0';
    return std::string_view{buffer.data(), value.size()};
  }

  tbc::val_a<ds::Option<std::string_view>> SessionFiles::join(std::string_view root, std::string_view suffix, tbc::val_a<std::span<char>> buffer) noexcept {
    return root.empty() ? ds::none : GitFiles::join(root, suffix, buffer);
  }

}
