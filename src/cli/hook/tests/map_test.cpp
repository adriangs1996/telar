#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.testing;
import telar.testing.test_memory;
import telar.cli.hook;
import telar.platform.paths;
import telar.platform.process;
import telar.wire.vocabulary;
import telar.cli.hooks.command;
import telar.cli.hooks.session;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli::hooks;

  // One agent event through `hooks::map`, as `telar hook PROVIDER` maps it before reporting.
  struct Mapped {
    Mapped(AgentProvider provider, std::string_view input)
        : adapter(system),
          payload(adapter, provider, JsonValue::parse(input)) {
      map(payload, reports, texts, files, process_environment);
    }

    SystemAllocator system;
    MemoryAdapter<SystemAllocator> adapter;
    Payload payload;
    Reports reports;
    ReportTexts texts;
    SessionFiles files;
  };

  bool lifecycle(const Reports& reports, AgentReportState state, AgentBlockedReason reason = AgentBlockedReason::none) {
    return reports.lifecycle && reports.lifecycle->state == state && reports.lifecycle->blocked_reason == reason;
  }

  bool rejected(AgentProvider provider, std::string_view input) {
    telar::testing::TestMemory adapter;

    try {
      Payload payload{adapter, provider, JsonValue::parse(input)};
    } catch (const std::invalid_argument&) {
      return true;
    }

    return false;
  }

  // Whether the runtime's codec accepts the report: the hook sends it with a pane and a request.
  template <typename Message>
  bool encodes(Message message) {
    message.request_id = 1;
    message.pane_id = 17;
    try {
      std::vector<Byte> bytes(Codec::encodedSize(message));

      static_cast<void>(Codec::encode(message, std::span<Byte>{bytes}));
      return true;
    } catch (const std::exception&) {
      return false;
    }
  }

  bool encodes(const Reports& reports) {
    return (!reports.lifecycle || encodes(*reports.lifecycle)) && (!reports.command || encodes(*reports.command)) && (!reports.title || encodes(*reports.title)) && (!reports.progress || encodes(*reports.progress));
  }

  class Directory {
  public:
    Directory() {
      std::strcpy(path_.dataMut(), "/tmp/telar-hook-map.XXXXXX");
      check(::mkdtemp(path_.dataMut()) != nullptr);
    }

    ~Directory() {
      std::error_code ignored;

      std::filesystem::remove_all(path_.data(), ignored);
    }

    std::string path(std::string_view name = {}) const {
      return name.empty() ? std::string{path_.data()} : std::string{path_.data()} + "/" + std::string{name};
    }

    std::string write(std::string_view name, std::string_view text) const {
      const auto file = path(name);

      std::ofstream{file, std::ios::binary} << text;
      return file;
    }

  private:
    ds::Array<char, 64> path_{};
  };

  void git(std::string_view directory, std::initializer_list<std::string_view> arguments) {
    SystemAllocator system;
    std::vector<std::string_view> complete{"git", "-c", "user.name=Hook Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"};

    complete.insert(complete.end(), arguments);
    Command command{system, Launch{.cwd = directory, .arguments = complete}, CommandPurpose::administration};
    CommandOutput output{system, 4096};

    check(output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{10}) == 0);
  }

  // Agent text with escapes, DEL and line breaks never makes a report the codec refuses,
  // which the hook would drop without a trace; a 2-byte character cut at the edge neither.
  void reportsStayEncodable() {
    const std::string hostile = R"(\u001b[31mred\u007f\nnext\tline)";
    const std::string edge = std::string(95, 'a') + "é";

    for (const auto& text : {hostile, edge}) {
      const auto notification = R"({"hook_event_name":"Notification","notification_type":"permission_prompt","message":")" + text + R"("})";
      const auto stop = R"({"hook_event_name":"Stop","last_assistant_message":")" + text + R"("})";
      const auto task = R"({"hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":")" + text + R"("}})";
      const auto question = R"({"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":")" + text + R"("}]}})";
      const auto bash = R"({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t","cwd":"/w","tool_input":{"command":")" + text + R"("}})";

      for (const auto& input : {notification, stop, task, question, bash}) {
        Mapped mapped{AgentProvider::claude, input};

        check(!mapped.reports.empty(), input);
        check(encodes(mapped.reports), input);
      }
    }

    Mapped stop{AgentProvider::claude, R"({"hook_event_name":"Stop","last_assistant_message":"\u001b[1mdone\u001b[0m"})"};

    check(stop.reports.progress && stop.reports.progress->final_message == "[1mdone[0m");
  }

  // A title an agent sets with an escape, DEL or a line break reaches the pane: the codec refuses
  // control bytes in a title, so an unfiltered one is lost.
  void titlesStayEncodable() {
    const ds::Array titles{
        std::pair{AgentProvider::claude, std::string_view{R"({"hook_event_name":"SessionStart","session_title":"\u001b]0;evil\u0007Fix\nbug\u007f"})"}},
        std::pair{AgentProvider::pi, std::string_view{R"({"event":"session_info_changed","name":"\u001b]0;evil\u0007Fix\nbug\u007f"})"}},
        std::pair{AgentProvider::opencode, std::string_view{R"({"event":"session.updated","title":"\u001b]0;evil\u0007Fix\nbug\u007f"})"}},
    };

    for (const auto& [provider, input] : titles) {
      Mapped mapped{provider, input};

      check(mapped.reports.title.hasValue(), input);
      check(encodes(*mapped.reports.title), input);
    }
  }

  // History records the command, its phase and its exit code as each agent reports them.
  void commandReportPhases() {
    Mapped started{AgentProvider::claude, R"({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t1","session_id":"s1","cwd":"/w","tool_input":{"command":"ls"}})"};

    check(started.reports.command && started.reports.command->phase == AgentCommandPhase::started);
    check(started.reports.command->command == "ls" && started.reports.command->cwd == "/w" && started.reports.command->tool_call_id == "t1");
    check(!started.reports.command->exit_code);

    Mapped finished{AgentProvider::claude, R"({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t1","cwd":"/w","tool_input":{"command":"ls"}})"};

    check(finished.reports.command && finished.reports.command->phase == AgentCommandPhase::finished && finished.reports.command->exit_code == 0);

    // Codex does not say how a command ended.
    Mapped codex{AgentProvider::codex, R"({"hook_event_name":"PostToolUse","tool_name":"exec_command","tool_use_id":"t2","cwd":"/w","tool_input":{"cmd":"make"}})"};

    check(codex.reports.command && codex.reports.command->phase == AgentCommandPhase::finished && codex.reports.command->command == "make" && !codex.reports.command->exit_code);

    Mapped pi{AgentProvider::pi, R"({"event":"tool_execution_end","tool_name":"bash","tool_call_id":"t3","cwd":"/w","exit_code":3,"tool_input":{"command":"false"}})"};

    check(pi.reports.command && pi.reports.command->phase == AgentCommandPhase::finished && pi.reports.command->exit_code == 3 && pi.reports.command->tool_call_id == "t3");

    // Cursor reports the exit code inside the tool's output and the directory as its workspace.
    Mapped cursor{AgentProvider::cursor, R"({"hook_event_name":"postToolUse","tool_name":"Shell","tool_use_id":"t4","cwd":"","workspace_roots":["/ws"],"tool_output":"{\"exitCode\":2}","tool_input":{"command":"make"}})"};

    check(cursor.reports.command && cursor.reports.command->phase == AgentCommandPhase::finished && cursor.reports.command->exit_code == 2);
    check(cursor.reports.command->cwd == "/ws");

    for (const auto input : {
             std::string_view{R"({"hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"t","tool_input":{"file_path":"/w/a"}})"},
             std::string_view{R"({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t","tool_input":{"command":""}})"},
             std::string_view{R"({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t","agent_id":"sub","tool_input":{"command":"ls"}})"},
         }) {
      Mapped none{AgentProvider::claude, input};

      check(!none.reports.command, input);
    }
  }

  // A subagent's events keep the parent's pane working: no ready, no command, no title, no progress.
  void subagentEventsStayOutOfParent() {
    ::setenv("CODEX_HOME", "/nonexistent-telar-hook-test", 1);
    for (const auto provider : {AgentProvider::claude, AgentProvider::codex}) {
      Mapped tool{provider, R"({"hook_event_name":"PreToolUse","agent_id":"sub","session_id":"s1","cwd":"/w","tool_name":"Bash","tool_use_id":"t","tool_input":{"command":"ls"}})"};

      check(lifecycle(tool.reports, AgentReportState::continuing));
      check(!tool.reports.command && !tool.reports.progress && !tool.reports.title);

      Mapped stop{provider, R"({"hook_event_name":"Stop","agent_id":"sub","session_id":"s1","cwd":"/w","last_assistant_message":"done"})"};

      check(!stop.reports.lifecycle && !stop.reports.progress);
    }

    Mapped start{AgentProvider::claude, R"({"hook_event_name":"SessionStart","agent_id":"sub","session_title":"Subagent"})"};

    check(!start.reports.title);
  }

  // The event-to-state map of Claude Code's hooks.
  void claudeLifecycle() {
    check(lifecycle(Mapped{AgentProvider::claude, R"({"hook_event_name":"SessionStart","session_id":"s1"})"}.reports, AgentReportState::ready));
    check(lifecycle(Mapped{AgentProvider::claude, R"({"hook_event_name":"UserPromptSubmit"})"}.reports, AgentReportState::working));

    Mapped question{AgentProvider::claude, R"({"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which branch?"},{"question":"Second"}]}})"};

    check(lifecycle(question.reports, AgentReportState::blocked, AgentBlockedReason::question));
    check(question.reports.lifecycle->event == "Which branch?");
    check(lifecycle(Mapped{AgentProvider::claude, R"({"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}})"}.reports, AgentReportState::blocked, AgentBlockedReason::plan));
    check(lifecycle(Mapped{AgentProvider::claude, R"({"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow?"})"}.reports, AgentReportState::blocked, AgentBlockedReason::permission));
    check(lifecycle(Mapped{AgentProvider::claude, R"({"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"Pick"})"}.reports, AgentReportState::blocked, AgentBlockedReason::question));
    check(lifecycle(Mapped{AgentProvider::claude, R"({"hook_event_name":"Notification","notification_type":"idle_prompt"})"}.reports, AgentReportState::idle));
    check(!Mapped{AgentProvider::claude, R"({"hook_event_name":"Notification","notification_type":"auth_success"})"}.reports.lifecycle);

    // A closed session is not offered for resuming.
    Mapped end{AgentProvider::claude, R"({"hook_event_name":"SessionEnd","session_id":"s1"})"};

    check(lifecycle(end.reports, AgentReportState::exited) && end.reports.lifecycle->session.empty());
  }

  void codexLifecycle() {
    ::setenv("CODEX_HOME", "/nonexistent-telar-hook-test", 1);
    check(lifecycle(Mapped{AgentProvider::codex, R"({"hook_event_name":"SessionStart","source":"compact"})"}.reports, AgentReportState::working));
    check(lifecycle(Mapped{AgentProvider::codex, R"({"hook_event_name":"SessionStart","source":"startup"})"}.reports, AgentReportState::ready));
    check(lifecycle(Mapped{AgentProvider::codex, R"({"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm x"}})"}.reports, AgentReportState::blocked, AgentBlockedReason::permission));
    check(lifecycle(Mapped{AgentProvider::codex, R"({"hook_event_name":"Stop"})"}.reports, AgentReportState::settling));
    check(lifecycle(Mapped{AgentProvider::codex, R"({"hook_event_name":"Interrupt"})"}.reports, AgentReportState::ready));

    Mapped end{AgentProvider::codex, R"({"hook_event_name":"SessionEnd","session_id":"s1"})"};

    check(lifecycle(end.reports, AgentReportState::exited) && end.reports.lifecycle->session.empty());
  }

  std::string activity(std::string_view kind, std::string_view agent) {
    return R"({"type":"event","item":{"type":"SubAgentActivity","kind":")" + std::string{kind} + R"(","agent_thread_id":")" + std::string{agent} + "\"}}\n";
  }

  // Codex's transcript says which subagents still run: the parent waits for them, and the last
  // one to finish releases it.
  void codexRunningSubagents() {
    ::setenv("CODEX_HOME", "/nonexistent-telar-hook-test", 1);
    const Directory directory;
    const auto parent = directory.write("rollout-s1.jsonl", activity("started", "A") + activity("started", "B") + activity("completed", "A"));
    const auto stop = R"({"hook_event_name":"Stop","session_id":"s1","transcript_path":")" + parent + "\"}";

    check(lifecycle(Mapped{AgentProvider::codex, stop}.reports, AgentReportState::waiting));

    // B's own SubagentStop does not count B among the subagents still running.
    const auto finished = R"({"hook_event_name":"SubagentStop","agent_id":"B","session_id":"s1","transcript_path":")" + parent + "\"}";

    check(lifecycle(Mapped{AgentProvider::codex, finished}.reports, AgentReportState::released));

    // An item that straddles the transcript's 64 KiB read window still counts.
    const auto straddling = directory.write("rollout-s2.jsonl", std::string(64 * 1024 - 60, ' ') + "\n" + activity("started", "C"));
    const auto later = R"({"hook_event_name":"Stop","session_id":"s2","transcript_path":")" + straddling + "\"}";

    check(lifecycle(Mapped{AgentProvider::codex, later}.reports, AgentReportState::waiting));

    // A FIFO in place of the transcript is not waited on.
    const auto fifo = directory.path("rollout-s3.jsonl");

    check(::mkfifo(fifo.c_str(), 0600) == 0);
    const auto blocked = R"({"hook_event_name":"Stop","session_id":"s3","transcript_path":")" + fifo + "\"}";

    check(lifecycle(Mapped{AgentProvider::codex, blocked}.reports, AgentReportState::settling));
  }

  void piLifecycleAndTitle() {
    check(lifecycle(Mapped{AgentProvider::pi, R"({"event":"session_start","session_id":"s1"})"}.reports, AgentReportState::ready));
    check(lifecycle(Mapped{AgentProvider::pi, R"({"event":"agent_start"})"}.reports, AgentReportState::working));
    check(lifecycle(Mapped{AgentProvider::pi, R"({"event":"ui_prompt_start"})"}.reports, AgentReportState::blocked, AgentBlockedReason::question));
    check(lifecycle(Mapped{AgentProvider::pi, R"({"event":"state_snapshot","idle":false,"blocked":true})"}.reports, AgentReportState::blocked, AgentBlockedReason::question));

    Mapped shutdown{AgentProvider::pi, R"({"event":"session_shutdown","session_id":"s1"})"};

    check(lifecycle(shutdown.reports, AgentReportState::exited) && shutdown.reports.lifecycle->session.empty());

    // A session that loses its name clears the pane's title.
    Mapped unnamed{AgentProvider::pi, R"({"event":"session_info_changed"})"};

    check(unnamed.reports.title && unnamed.reports.title->title.empty());

    Mapped named{AgentProvider::pi, R"({"event":"session_info_changed","name":"Refactor"})"};

    check(named.reports.title && named.reports.title->title == "Refactor");
    check(rejected(AgentProvider::pi, R"({"event":"state_snapshot","blocked":"yes"})"));
  }

  void openCodeLifecycleAndTitle() {
    check(lifecycle(Mapped{AgentProvider::opencode, R"({"event":"tool.execute.before","tool_name":"bash","tool_input":{"command":"ls"}})"}.reports, AgentReportState::working));
    check(!Mapped{AgentProvider::opencode, R"({"event":"tool.execute.before","blocked":"permission","tool_name":"bash"})"}.reports.lifecycle);
    check(lifecycle(Mapped{AgentProvider::opencode, R"({"event":"session.status","busy":false})"}.reports, AgentReportState::ready));
    check(lifecycle(Mapped{AgentProvider::opencode, R"({"event":"session.status","busy":true})"}.reports, AgentReportState::working));
    check(lifecycle(Mapped{AgentProvider::opencode, R"({"event":"permission.asked","blocked":"permission","tool_name":"bash"})"}.reports, AgentReportState::blocked, AgentBlockedReason::permission));
    check(lifecycle(Mapped{AgentProvider::opencode, R"({"event":"question.asked","blocked":"question"})"}.reports, AgentReportState::blocked, AgentBlockedReason::question));
    check(rejected(AgentProvider::opencode, R"({"event":"question.asked","blocked":"later"})"));

    Mapped dispose{AgentProvider::opencode, R"({"event":"dispose","session_id":"s1"})"};

    check(lifecycle(dispose.reports, AgentReportState::exited) && dispose.reports.lifecycle->session.empty());

    // OpenCode's generated title does not replace the pane's.
    for (const auto input : {std::string_view{R"({"event":"session.updated","title":"New session - 2025-01-01T00:00:00.000Z"})"}, std::string_view{R"({"event":"session.updated","title":"Child session - 2025-01-01T00:00:00.000Z"})"}}) {
      Mapped generated{AgentProvider::opencode, input};

      check(generated.reports.title && generated.reports.title->title.empty(), input);
    }

    Mapped titled{AgentProvider::opencode, R"({"event":"session.updated","title":"New session - fix login"})"};

    check(titled.reports.title && titled.reports.title->title == "New session - fix login");
  }

  void cursorLifecycle() {
    ::setenv("CURSOR_CONFIG_DIR", "/nonexistent-telar-hook-test", 1);
    for (const auto input : {std::string_view{R"({"hook_event_name":"sessionStart"})"}, std::string_view{R"({"hook_event_name":"stop"})"}}) {
      check(lifecycle(Mapped{AgentProvider::cursor, input}.reports, AgentReportState::ready), input);
    }

    for (const auto input : {
             std::string_view{R"({"hook_event_name":"beforeSubmitPrompt"})"},
             std::string_view{R"({"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"ls"}})"},
             std::string_view{R"({"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"ls"}})"},
             std::string_view{R"({"hook_event_name":"postToolUseFailure","tool_name":"Shell","tool_input":{"command":"ls"}})"},
         }) {
      check(lifecycle(Mapped{AgentProvider::cursor, input}.reports, AgentReportState::working), input);
    }

    check(lifecycle(Mapped{AgentProvider::cursor, R"({"hook_event_name":"sessionEnd"})"}.reports, AgentReportState::exited));
    check(!Mapped{AgentProvider::cursor, R"({"hook_event_name":"afterFileEdit"})"}.reports.lifecycle);
  }

  // The task list a pane shows follows Claude's and Codex's plan tools.
  void progressPlanOps() {
    Mapped created{AgentProvider::claude, R"({"hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Write the tests"}})"};

    check(created.reports.progress && created.reports.progress->plan_op == AgentPlanOp::add && created.reports.progress->plan_text == "Write the tests");

    // Claude numbers tasks from 1.
    Mapped updated{AgentProvider::claude, R"({"hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"3","status":"completed"}})"};

    check(updated.reports.progress && updated.reports.progress->plan_op == AgentPlanOp::mark);
    check(updated.reports.progress->plan_index == 2 && updated.reports.progress->plan_status == AgentPlanStatus::completed);
    check(!Mapped{AgentProvider::claude, R"({"hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"0","status":"completed"}})"}.reports.progress);
    check(!Mapped{AgentProvider::claude, R"({"hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"blocked"}})"}.reports.progress);

    ::setenv("CODEX_HOME", "/nonexistent-telar-hook-test", 1);
    Mapped plan{AgentProvider::codex, R"({"hook_event_name":"PostToolUse","tool_name":"update_plan","tool_input":{"plan":[{"step":"a","status":"completed"},{"step":"b","status":"in_progress"},{"step":"c","status":"deleted"},{"step":"d","status":"pending"}]}})"};

    check(plan.reports.progress && plan.reports.progress->plan_op == AgentPlanOp::set);
    check(plan.reports.progress->plan_total == 3 && plan.reports.progress->plan_done == 1 && plan.reports.progress->plan_text == "b");

    // A new session starts with an empty plan.
    Mapped start{AgentProvider::claude, R"({"hook_event_name":"SessionStart"})"};

    check(start.reports.progress && start.reports.progress->plan_op == AgentPlanOp::set && start.reports.progress->plan_total == 0);
  }

  // The pane follows the agent's directory, and names the linked worktree it is in.
  void progressCwdAndWorktree() {
    Mapped changed{AgentProvider::claude, R"({"hook_event_name":"CwdChanged","cwd":"/old","new_cwd":"/abs"})"};

    check(changed.reports.progress && changed.reports.progress->cwd == "/abs");
    check(!Mapped{AgentProvider::claude, R"({"hook_event_name":"CwdChanged","new_cwd":"relative/dir"})"}.reports.progress);

    const Directory directory;
    const auto repository = directory.path("repository");
    const auto linked = directory.path("linked");

    std::filesystem::create_directory(repository);
    git(repository, {"init", "--quiet", "--initial-branch=main", "--template="});
    git(repository, {"commit", "--quiet", "--allow-empty", "-m", "Initial fixture"});
    git(repository, {"worktree", "add", "--quiet", "-b", "feature/x", linked});
    std::filesystem::create_directory(linked + "/src");
    const auto input = R"({"hook_event_name":"CwdChanged","new_cwd":")" + linked + R"(/src"})";
    Mapped inside{AgentProvider::claude, input};

    check(inside.reports.progress && inside.reports.progress->cwd == linked + "/src");
    check(inside.reports.progress->work_tree_path == linked && inside.reports.progress->work_tree_branch == "feature/x");
  }

  // The runtime opens the newest Codex state database: versions compare as numbers.
  void codexSessionFileNewest() {
    const Directory directory;
    const auto home = directory.path("codex");

    std::filesystem::create_directories(home + "/state_99.sqlite");
    for (const auto name : {"state_3.sqlite", "state_12.sqlite", "state_x.sqlite"}) {
      directory.write(std::string{"codex/"} + name, "");
    }

    ::setenv("CODEX_HOME", home.c_str(), 1);
    Mapped configured{AgentProvider::codex, R"({"hook_event_name":"SessionStart","session_id":"s1"})"};

    check(configured.reports.lifecycle && configured.reports.lifecycle->session_file == home + "/state_12.sqlite");
    check(configured.reports.lifecycle->session_file_kind == AgentSessionFileKind::codex_state);

    // Without CODEX_HOME, Codex keeps its state under the home directory.
    std::filesystem::create_directories(directory.path(".codex"));
    directory.write(".codex/state_5.sqlite", "");
    ::unsetenv("CODEX_HOME");
    ::setenv("HOME", directory.path().c_str(), 1);
    Mapped defaulted{AgentProvider::codex, R"({"hook_event_name":"SessionStart","session_id":"s1"})"};

    check(defaulted.reports.lifecycle && defaulted.reports.lifecycle->session_file == directory.path(".codex/state_5.sqlite"));
  }

  // The runtime reads Cursor's chat metadata only from a regular file inside the chats of the
  // configured directory, whatever conversation id the agent sends.
  void cursorSessionFileConfined() {
    const Directory directory;
    const auto chats = directory.path("chats/948361d4354174853dd04ced978d78d1");
    constexpr std::string_view start = R"({"hook_event_name":"sessionStart","workspace_roots":["/ws"],"conversation_id":")";

    std::filesystem::create_directories(chats + "/0f1e2d3c-aaaa");
    std::filesystem::create_directories(chats + "/0f1e2d3c-bbbb");
    std::filesystem::create_directories(directory.path("secret"));
    directory.write("chats/948361d4354174853dd04ced978d78d1/0f1e2d3c-aaaa/meta.json", "{}");
    directory.write("secret/meta.json", "{}");
    std::filesystem::create_symlink(directory.path("secret/meta.json"), chats + "/0f1e2d3c-bbbb/meta.json");
    ::setenv("CURSOR_CONFIG_DIR", directory.path().c_str(), 1);
    const auto found = std::string{start} + R"(0f1e2d3c-aaaa"})";
    Mapped chat{AgentProvider::cursor, found};

    check(chat.reports.lifecycle && chat.reports.lifecycle->session_file == chats + "/0f1e2d3c-aaaa/meta.json");
    check(chat.reports.lifecycle->session_file_kind == AgentSessionFileKind::cursor_meta);

    for (const auto conversation : {"../../secret", "0f1e2d3c/../../../secret", "0f1e2d3c-bbbb"}) {
      const auto input = std::string{start} + conversation + "\"}";
      Mapped refused{AgentProvider::cursor, input};

      check(refused.reports.lifecycle && refused.reports.lifecycle->session_file.empty(), input);
    }
  }

  const telar::testing::Case case_reports_stay_encodable{"hooks.reports_stay_encodable", reportsStayEncodable};
  const telar::testing::Case case_titles_stay_encodable{"hooks.titles_stay_encodable", titlesStayEncodable};
  const telar::testing::Case case_command_report_phases{"hooks.command_report_phases", commandReportPhases};
  const telar::testing::Case case_subagent_events_stay_out_of_parent{"hooks.subagent_events_stay_out_of_parent", subagentEventsStayOutOfParent};
  const telar::testing::Case case_claude_lifecycle{"hooks.claude_lifecycle", claudeLifecycle};
  const telar::testing::Case case_codex_lifecycle{"hooks.codex_lifecycle", codexLifecycle};
  const telar::testing::Case case_codex_running_subagents{"hooks.codex_running_subagents", codexRunningSubagents};
  const telar::testing::Case case_pi_lifecycle_and_title{"hooks.pi_lifecycle_and_title", piLifecycleAndTitle};
  const telar::testing::Case case_opencode_lifecycle_and_title{"hooks.opencode_lifecycle_and_title", openCodeLifecycleAndTitle};
  const telar::testing::Case case_cursor_lifecycle{"hooks.cursor_lifecycle", cursorLifecycle};
  const telar::testing::Case case_progress_plan_ops{"hooks.progress_plan_ops", progressPlanOps};
  const telar::testing::Case case_progress_cwd_and_worktree{"hooks.progress_cwd_and_worktree", progressCwdAndWorktree};
  const telar::testing::Case case_codex_session_file_newest{"hooks.codex_session_file_newest", codexSessionFileNewest};
  const telar::testing::Case case_cursor_session_file_confined{"hooks.cursor_session_file_confined", cursorSessionFileConfined};

}
