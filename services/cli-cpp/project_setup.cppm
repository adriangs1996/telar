module;

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <string>
#include <concepts>


#include <cerrno>
#include <cstddef>
#include <cstring>
#include <exception>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include "telar_client/codecs/telar_codec.hpp"
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_platform/random_bytes.hpp"
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <csignal>
#include <dirent.h>
#include <spawn.h>
#include <sys/wait.h>
#include <thread>
#include <chrono>


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <poll.h>
#include <format>


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <openssl/sha.h>


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#include "telar_client/serializers/telar_messages.hpp"
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <filesystem>
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include "telar_base/text/utf8.hpp"
#include <cmath>

export module telar.cli.project_setup;

export import telar.cli.command_limit;
export import telar.cli.plugin;
export import telar.base.text;


export import telar.cli.runtime_observer;
export import telar.cli.server;
export import telar.cli.output;


export import telar.cli.history;

// Interface: pane_agent_options.cppm
export {
namespace telar::runtime::cli::pane_agents {

inline constexpr std::size_t max_input_bytes = 65536;
inline constexpr std::uint16_t max_read_rows = 2000;
inline constexpr std::uint32_t max_timeout_seconds = 86400;
inline constexpr std::uint32_t default_interval_ms = 250;
inline constexpr std::uint32_t min_interval_ms = 10;
inline constexpr std::uint32_t max_interval_ms = 60000;

inline constexpr std::array<std::string_view, 9> report_states{"working", "blocked", "ready", "exited", "settling", "continuing", "waiting", "idle", "released"};
inline constexpr std::array<std::string_view, 5> blocked_reasons{"none", "permission", "question", "plan", "other"};
inline constexpr std::array<std::string_view, 3> session_file_kinds{"claude_transcript", "codex_state", "cursor_meta"};
inline constexpr std::array<std::string_view, 6> status_names{"unknown", "working", "blocked", "ready", "failed", "done"};

inline bool displayText(std::string_view text) {
  return inspectUtf8(text) == Utf8Validation::valid && std::none_of(text.begin(), text.end(), [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; });
}

struct Options {
  std::string_view action{};
  std::string_view target{};
  std::string_view text{};
  std::optional<std::string_view> workspace{};
  std::optional<std::string_view> tab{};
  const char *socket = nullptr;
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

inline void socketOption(Options &options, Cursor &cursor) {
  const auto value = cursor.take("MissingSocketPath");
  if (options.socket) {
    usage("DuplicateSocketOption");
  }

  options.socket = value.data();
}

inline void readOption(Options &options, Cursor &cursor, std::string_view option) {
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

inline Options parsePane(std::span<char *const> words) {
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
      auto &target = arg == "--workspace" ? options.workspace : options.tab;
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

inline Options parseAgent(std::span<char *const> words) {
  Cursor cursor{words};
  Options options{.action = cursor.take("MissingAgentAction")};
  const auto action = options.action;
  constexpr std::array<std::string_view, 11> actions{"list", "get", "wait", "prompt", "read", "interrupt", "acknowledge", "report-session", "report-title", "report-state", "report-command"};
  if (std::find(actions.begin(), actions.end(), action) == actions.end()) {
    usage("UnknownAgentAction");
  }

  if (action != "list") {
    options.target = cursor.take("MissingAgentTarget");
  }

  if (action == "report-command") {
    constexpr std::array<std::string_view, 2> phases{"started", "finished"};
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

}
}

// Interface: pane_agent_control.cppm
export {
namespace telar::runtime::cli::pane_agents {

inline constexpr auto poll_interval = std::chrono::milliseconds{250};
inline constexpr auto submit_delay = std::chrono::milliseconds{150};
inline constexpr auto start_grace = std::chrono::seconds{5};
inline constexpr auto interrupt_settle = std::chrono::seconds{15};


inline std::uint64_t current(const char *name, bool nonzero = false) {
  const auto text = ProcessEnvironment{}.lookup(name);
  const auto id = maybeUnsigned(text);
  if (!id || (nonzero && *id == 0)) {
    throw Failure{missing_pane_context};
  }

  return *id;
}

inline std::uint64_t paneId(std::string_view target) {
  if (target == "--current") {
    return current("TELAR_PANE_ID");
  }

  if (const auto id = maybeUnsigned(target)) {
    return *id;
  }

  throw Failure{"InvalidPaneId"};
}

inline std::uint64_t entityId(std::string_view target, const char *variable) {
  if (target == "--current") {
    const auto value = ProcessEnvironment{}.lookup(variable);
    if (value.empty()) {
      throw Failure{"MissingCurrentIdentity"};
    }

    try {
      return positive(value, "InvalidIdentity");
    } catch (const std::invalid_argument &) {
      throw Failure{"InvalidIdentity"};
    }
  }

  return positive(target, "InvalidIdentity");
}

inline void validateBytes(std::string_view value, std::size_t maximum, bool empty = true) {
  if (value.size() > maximum || (!empty && value.empty())) {
    throw Failure{"InvalidByteString"};
  }

  if (value.find('\0') != std::string_view::npos) {
    throw Failure{"EmbeddedNul"};
  }
}

inline void validateSession(std::string_view value) {
  try {
    validateAgentSession(value, false);
  } catch (const EncodingError &) {
    throw Failure{"InvalidSessionReference"};
  }
}

inline void validateReport(const Options &options) {
  if (options.action == "report-state") {
    const auto &report = options.report;
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
    const auto &command = options.command;
    validateBytes(command.provider, 64, false);
    validateBytes(command.tool_call_id, 256);
    validateBytes(command.command, max_input_bytes, false);
    validateBytes(command.cwd, 4096);
    if (!command.session.empty()) {
      validateSession(command.session);
    }
  }
}

inline bool equalTitle(std::string_view left, std::string_view right) {
  return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(), [](unsigned char a, unsigned char b) {
           const auto lower = [](unsigned char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; };
           return lower(a) == lower(b);
         });
}

inline ServerOptions socketOptions(const char *socket) {
  ServerOptions options;
  options.socket = socket ? socket : "";
  return options;
}

// Zig's `Session.attach` (start false) or `Session.open`: a connection
// failure ends the command as Zig's escapes to main, `error: NAME`.
template <Allocator Memory>
void connectRuntime(Memory &memory, const RuntimePaths<Memory> &paths, bool start) {
  try {
    const RuntimeConnection probe{paths.socket.c_str()};
    return;
  } catch (const SystemError &error) {
    if (!start || (error.code() != ENOENT && error.code() != ECONNREFUSED)) {
      throw CommandError{systemErrorName(error.code())};
    }
  }

  if (startRuntime(memory, ServerOptions{}, paths) != RuntimeStart::listening) {
    throw CommandError{"RuntimeUnavailable"};
  }
}


template <Allocator Memory>
void writeAgent(Output<Memory> &out, const AgentSnapshotEntry &agent, bool json) {
  const auto provider = agent.provider_name.empty() ? std::string_view{"unknown"} : agent.provider_name;
  const auto status = status_names[static_cast<std::size_t>(agent.status)];
  if (json) {
    out.text("{\"pane_id\":").number(agent.pane_id).text(",\"pane_generation\":").number(agent.pane_generation).text(",\"workspace_id\":").number(agent.location.workspace.id).text(",\"tab_id\":").number(agent.location.tab_id).text(",\"pane_index\":").number(agent.pane_index).text(",\"provider\":").json(provider, JsonEscapes::control).text(",\"provider_index\":").number(static_cast<unsigned>(agent.provider)).text(",\"status\":").json(status, JsonEscapes::control);
    out.text(",\"workspace\":").json(agent.workspace_label, JsonEscapes::control).text(",\"tab\":").json(agent.tab_label, JsonEscapes::control).text(",\"title\":").json(agent.session_title, JsonEscapes::control).text(",\"cwd\":").json(agent.cwd_label, JsonEscapes::control).text(",\"blocked_reason\":").json(blocked_reasons[static_cast<std::size_t>(agent.blocked_reason)], JsonEscapes::control).text(",\"status_age_s\":").number(agent.status_age_s).text(",\"worktree_id\":").number(agent.work_tree).text(",\"last_event\":").json(agent.last_event, JsonEscapes::control);
    out.text(",\"plan\":{\"done\":").number(agent.plan_done).text(",\"total\":").number(agent.plan_total).text(",\"step\":").json(agent.plan_step, JsonEscapes::control).text("},\"final_message\":").json(agent.final_message, JsonEscapes::control).text(",\"session_id\":\"");
    constexpr std::string_view hex = "0123456789abcdef";
    for (const auto byte : agent.session_id) {
      out.text(hex.substr(byte >> 4, 1)).text(hex.substr(byte & 15, 1));
    }

    out.text("\"}");
    return;
  }

  const auto column = [&](std::string_view text, std::size_t width) {
    out.text(text);
    if (text.size() < width) {
      out.data.append(width - text.size(), ' ');
    }
  };
  const auto numeric = [&](std::uint64_t value, std::size_t width) {
    const auto start = out.data.size();
    out.number(value);
    const auto used = out.data.size() - start;
    if (used < width) {
      out.data.append(width - used, ' ');
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

inline constexpr std::string_view agent_header = "PANE  GEN  STATUS   PROV    WORKSPACE         TAB           TITLE\n";

template <Allocator Memory>
void writeOne(Output<Memory> &out, const AgentSnapshotEntry &agent, bool json) {
  if (!json) {
    out.text(agent_header);
  }

  writeAgent(out, agent, json);
  if (json) {
    out.text("\n");
  }
}

template <Allocator Memory>
void writeText(Output<Memory> &out, const PaneText &reply, bool json, bool agent) {
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

template <Allocator Memory>
WorkspaceList runtimeList(ControlSession<Memory> &session) {
  session.send(RequestRuntimeState{.client_identity = static_cast<std::uint64_t>(::getpid()), .interactive = false});
  return session.template receive<WorkspaceList>();
}

template <Allocator Memory>
Vector<PaneRecord, Memory> paneCatalog(Memory &memory, const char *socket, const Options &options) {
  ControlSession session{memory, socket};
  session.receiveTimeout(30);
  Vector<std::uint64_t, Memory> workspaces{AllocatorRef<std::uint64_t, Memory>{memory}};
  Vector<PaneRecord, Memory> records{AllocatorRef<PaneRecord, Memory>{memory}};
  if (options.workspace) {
    workspaces.push_back(entityId(*options.workspace, "TELAR_WORKSPACE_ID"));
  } else {
    for (const auto &entry : runtimeList(session).entries) {
      workspaces.push_back(entry.workspace);
    }
  }

  for (const auto workspace : workspaces) {
    Vector<std::uint64_t, Memory> tabs{AllocatorRef<std::uint64_t, Memory>{memory}};
    const WorkspaceLocation location{.id = workspace};
    if (options.tab) {
      tabs.push_back(entityId(*options.tab, "TELAR_TAB_ID"));
    } else {
      const auto snapshot = session.template exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.workspace = location});
      if (snapshot.workspace.kind != location.kind || snapshot.workspace.id != workspace) {
        throw Failure{"unexpected reply from the runtime"};
      }

      for (const auto &entry : snapshot.tabs) {
        tabs.push_back(entry.tab_id);
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
        records.push_back(PaneRecord{.location = target, .position = position++, .pane = pane});
      }
    }
  }

  return records;
}

template <Allocator Memory>
std::uint64_t worktreeId(Memory &memory, const char *socket, std::string_view reference) {
  ControlSession session{memory, socket};
  session.receiveTimeout(30);
  const auto list = runtimeList(session);
  for (const bool branch : {true, false}) {
    std::optional<std::uint64_t> found;
    for (const auto &tree : list.worktrees) {
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

inline AgentSnapshotEntry resolve(const AgentSnapshot &snapshot, std::string_view target, std::optional<std::uint64_t> worktree = std::nullopt) {
  const auto wanted = target == "--current" ? std::optional{current("TELAR_PANE_ID")} : maybeUnsigned(target);
  std::optional<AgentSnapshotEntry> found;
  for (const auto &entry : snapshot.entries) {
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

inline std::optional<std::uint64_t> senderPane(const Options &options, std::uint64_t target) {
  const ProcessEnvironment environment;
  const auto id = maybeUnsigned(environment.lookup("TELAR_PANE_ID"));
  const auto own = environment.lookup("TELAR_SOCKET_PATH");
  if (!id || *id == target || own.empty()) {
    return std::nullopt;
  }

  const auto socket = options.socket ? std::string_view{options.socket} : environment.lookup("TELAR_SOCKET");
  if (!socket.empty() && socket != own) {
    return std::nullopt;
  }

  if (*id == 0) {
    throw Failure{"InvalidPaneId"};
  }

  return id;
}

inline int commandFailure(const char *family, const std::exception &error) {
  const auto *system = dynamic_cast<const SystemError *>(&error);
  const auto socket_timeout = dynamic_cast<const SocketError *>(&error) && (errno == EAGAIN || errno == EWOULDBLOCK);
  const auto timeout = socket_timeout || (system && (system->code() == EAGAIN || system->code() == EWOULDBLOCK));
  std::fprintf(stderr, "%s: %s\n", family, timeout ? "RuntimeTimeout" : error.what());
  if (timeout) {
    return 1;
  }

  if (const auto *failure = dynamic_cast<const Failure *>(&error)) {
    return failure->status();
  }

  if (const auto *failure = dynamic_cast<const ControlFailure *>(&error)) {
    return (failure->code() == FailureCode::pane_not_found || failure->code() == FailureCode::pane_exited || (std::string_view{family} == "telar agent" && failure->code() == FailureCode::worktree_not_found)) ? 2 : 1;
  }

  return 1;
}

}
}

// Interface: agent.cppm
export {
namespace telar::runtime::cli::pane_agents {

template <Allocator Memory>
void interruptAgent(ControlSession<Memory> &session, const AgentSnapshotEntry &agent) {
  session.template exchange<RequestCompleted>(InterruptAgent{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation});
}

template <Allocator Memory>
int waitAgent(ControlSession<Memory> &session, const Options &options, std::optional<std::uint64_t> worktree, Output<Memory> &out) {
  const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds{options.timeout};
  for (;;) {
    const auto agent = resolve(session.template exchange<AgentSnapshot>(QueryAgents{}), options.target, worktree);
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

template <Allocator Memory>
void settleAgent(ControlSession<Memory> &session, AgentSnapshotEntry agent) {
  const auto pane = agent.pane_id;
  interruptAgent(session, agent);
  const auto deadline = std::chrono::system_clock::now() + interrupt_settle;
  while (std::chrono::system_clock::now() < deadline) {
    std::this_thread::sleep_for(poll_interval);
    const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
    const auto found = std::find_if(snapshot.entries.begin(), snapshot.entries.end(), [&](const auto &entry) { return entry.pane_id == pane; });
    if (found == snapshot.entries.end()) {
      throw Failure{"no agent matches that target", 2};
    }

    if (found->status != AgentStatus::working) {
      return;
    }
  }

  throw Failure{"InterruptNotSettled"};
}

template <Allocator Memory>
int promptAgent(ControlSession<Memory> &session, const Options &options, AgentSnapshotEntry agent, Output<Memory> &out) {
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
    const auto found = std::find_if(snapshot.entries.begin(), snapshot.entries.end(), [&](const auto &entry) { return entry.pane_id == pane; });
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

template <Allocator Memory>
void reportAgent(ControlSession<Memory> &session, const Options &options, const std::pair<std::uint64_t, std::uint64_t> &pane, Output<Memory> &out) {
  try {
    session.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = pane.first, .pane_generation = pane.second});
  } catch (const std::exception &) {
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

template <Allocator Memory>
int executeAgent(Memory &memory, const RuntimePaths<Memory> &paths, const Options &options, Output<Memory> &out) {
  ControlSession session{memory, paths.socket.c_str()};
  session.receiveTimeout(30);
  const bool report = options.action == "report-title" || options.action == "report-state" || options.action == "report-command";
  std::optional<std::uint64_t> tree;
  constexpr std::string_view prefix = "worktree:";
  if (options.target.starts_with(prefix) && options.target.size() > prefix.size()) {
    if (report) {
      ControlSession catalog{memory, paths.socket.c_str()};
      catalog.receiveTimeout(30);
      runtimeList(catalog);
    } else {
      tree = worktreeId(memory, paths.socket.c_str(), options.target.substr(prefix.size()));
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
    for (const auto &agent : snapshot.entries) {
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
    const auto again = resolve(session.template exchange<AgentSnapshot>(QueryAgents{}), options.target, tree);
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
    const auto found = std::find_if(updated.entries.begin(), updated.entries.end(), [&](const auto &entry) { return entry.pane_id == pane; });
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

template <Allocator Memory>
int runAgent(Memory &memory, const pane_agents::Options &options) {
  using namespace pane_agents;
  const RuntimePaths paths{memory, socketOptions(options.socket), ProcessEnvironment{}};
  connectRuntime(memory, paths, options.action != "acknowledge" && options.action != "report-title" && options.action != "report-state" && options.action != "report-command");
  Output out{memory};
  try {
    const auto result = executeAgent(memory, paths, options, out);
    out.flush();
    return result;
  } catch (const std::exception &error) {
    out.flush();
    return commandFailure("telar agent", error);
  }
}

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
    list
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

  inline static ExecutionOptions parse(Arguments words) {
    ExecutionOptions self;
    Cursor cursor{words};
    constexpr std::array names{"start", "status", "output", "cancel", "forget", "list"};
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

        std::ranges::copy(command, self.arguments.begin());
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
};

}
}

// Interface: execution.cppm
export {
namespace telar::runtime::cli::execution {

inline constexpr int failure_status = 125;
inline constexpr int timeout_status = 124;
inline constexpr std::chrono::milliseconds poll_interval{10};
inline constexpr std::size_t max_chunk = 4096;

inline std::string_view stateName(ExecutionState state) {
  constexpr std::array names{"starting", "running", "exited", "failed"};
  return names.at(static_cast<std::size_t>(state));
}

inline bool finished(const ExecutionReply &reply) {
  return reply.state == ExecutionState::exited || reply.state == ExecutionState::failed;
}

template <Allocator Memory>
ExecutionReply exchange(ControlSession<Memory> &session, ExecutionRequest request) {
  for (;;) {
    try {
      return session.template exchange<ExecutionReply>(request);
    } catch (const ControlFailure &error) {
      if (error.message() != "ExecutionBusy") {
        throw;
      }

      std::this_thread::sleep_for(poll_interval);
    }
  }
}

inline std::string statusJson(const ExecutionReply &reply) {
  return std::format("{{\"execution_id\":{},\"workspace_id\":{},\"state\":{},\"exit_code\":{},\"stdout_offset\":{},\"stderr_offset\":{},\"stdout_bytes\":{},\"stderr_bytes\":{},\"stdin_bytes\":{},\"stdin_open\":{},\"failure\":{}}}\n", reply.execution_id, reply.workspace_id, quoteJson(stateName(reply.state)), finished(reply) ? std::to_string(reply.exit_code) : "null", reply.stdout_offset, reply.stderr_offset, reply.stdout_total, reply.stderr_total, reply.input_offset, jsonBoolean(reply.stdin_open), quoteJson(textBytes(reply.failure)));
}

inline void writeStreams(ExecutionRequest &request, const ExecutionReply &reply) {
  if (request.stdout_offset != reply.stdout_offset || request.stderr_offset != reply.stderr_offset) {
    writeText(std::format("telar exec: retained output lost; resume with --stdout-offset {} --stderr-offset {}\n", reply.stdout_offset, reply.stderr_offset), STDERR_FILENO);
    throw std::runtime_error{"ExecutionOutputLost"};
  }

  writeBytes(STDOUT_FILENO, reply.stdout_bytes);
  writeBytes(STDERR_FILENO, reply.stderr_bytes);
  request.stdout_offset += reply.stdout_bytes.size();
  request.stderr_offset += reply.stderr_bytes.size();
}

template <Allocator Memory>
void list(ControlSession<Memory> &session) {
  ExecutionRequest request{.action = ExecutionAction::list};
  std::string output = "[";
  for (;;) {
    const auto reply = exchange(session, request);
    if (reply.execution_id == 0) {
      break;
    }

    if (request.execution_id != 0) {
      output += ',';
    }

    output += std::format("{{\"execution_id\":{},\"workspace_id\":{},\"state\":{},\"exit_code\":{}}}", reply.execution_id, reply.workspace_id, quoteJson(stateName(reply.state)), finished(reply) ? std::to_string(reply.exit_code) : "null");
    request.execution_id = reply.execution_id;
  }

  output += "]\n";
  writeText(output);
}

template <Allocator Memory>
int observe(ControlSession<Memory> &session, ExecutionRequest request, ExecutionReply reply, const ExecutionOptions &options) {
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
          writeText("telar exec: " + std::string{textBytes(reply.failure)} + "\n", STDERR_FILENO);
        }

        return std::clamp(reply.exit_code, 0, 255);
      }

      if (options.timeout_seconds != 0 && std::chrono::steady_clock::now() - started >= std::chrono::seconds{options.timeout_seconds}) {
        writeText(std::format("telar exec: wait timed out; execution {} continues\n", request.execution_id), STDERR_FILENO);
        return timeout_status;
      }

      if (stdin_open && reply.stdin_open && reply.input_available >= max_chunk) {
        pollfd input{.fd = STDIN_FILENO, .events = POLLIN, .revents = 0};
        if (::poll(&input, 1, 0) > 0) {
          std::array<Byte, max_chunk> bytes;
          const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
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

template <Allocator Memory>
int start(ControlSession<Memory> &session, const ExecutionOptions &options) {
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
      writeText(statusJson(reply));
      return 0;
    }

    return observe(session, request, reply, options);
  } catch (...) {
    if (options.action == ExecutionOptions::Action::start) {
      writeText(std::format("telar exec: query execution {} before retrying an uncertain launch\n", request.execution_id), STDERR_FILENO);
    }

    throw;
  }
}

template <Allocator Memory>
int run(Memory &memory, const ExecutionOptions &options) {
  try {
    ServerOptions server_options{};
    server_options.socket = options.socket;
    const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
    ensureRuntime(memory, paths);
    ControlSession session{memory, paths.socket.c_str()};
    session.receiveTimeout(30);
    return start(session, options);
  } catch (const ControlFailure &error) {
    writeText("telar exec: " + std::string{error.message().empty() ? error.what() : error.message()} + "\n", STDERR_FILENO);
  } catch (const std::exception &error) {
    writeText("telar exec: " + std::string{commandErrorName(error)} + "\n", STDERR_FILENO);
  }

  return failure_status;
}

}
}

// Interface: pane.cppm
export {
namespace telar::runtime::cli::pane_agents {

inline constexpr std::array<std::string_view, 3> focus_outcomes{"focused", "no_neighbor", "source_not_focused"};
inline constexpr std::array<std::string_view, 2> lifecycles{"running", "exited"};

template <Allocator Memory>
void writePane(Output<Memory> &out, const PaneRecord &entry, bool json) {
  const auto &pane = entry.pane;
  const auto lifecycle = lifecycles.at(static_cast<std::size_t>(pane.lifecycle));
  if (json) {
    out.text("{\"workspace_id\":").number(entry.location.workspace.id).text(",\"tab_id\":").number(entry.location.tab_id).text(",\"position\":").number(entry.position).text(",\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"lifecycle\":").json(lifecycle, JsonEscapes::standard).text("}");
  } else {
    out.number(entry.location.workspace.id).text("\t").number(entry.location.tab_id).text("\t").number(pane.pane_id).text("\t").number(pane.pane_generation).text("\t").text(lifecycle).text("\n");
  }
}

template <Allocator Memory>
void inspectPanes(Memory &memory, const char *socket, const Options &options, Output<Memory> &out) {
  const auto catalog = paneCatalog(memory, socket, options);
  if (options.action == "get") {
    const auto wanted = paneId(options.target);
    for (const auto &entry : catalog) {
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
  for (const auto &entry : catalog) {
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

template <Allocator Memory>
void watchPane(ControlSession<Memory> &session, const Options &options, const PaneDescriptor &pane, Output<Memory> &out) {
  std::optional<std::array<unsigned char, SHA256_DIGEST_LENGTH>> previous;
  bool previous_truncated = false;
  std::uint64_t count = 0;
  for (;;) {
    const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .rows = options.lines, .source = options.source});
    if (reply.pane_id != pane.pane_id) {
      throw Failure{"unexpected reply from the runtime"};
    }

    std::array<unsigned char, SHA256_DIGEST_LENGTH> digest;
    SHA256(reinterpret_cast<const unsigned char *>(reply.text.data()), reply.text.size(), digest.data());
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

template <Allocator Memory>
int executePane(Memory &memory, const RuntimePaths<Memory> &paths, Options options, Output<Memory> &out) {
  ControlSession session{memory, paths.socket.c_str()};
  session.receiveTimeout(30);
  String<Memory> input{AllocatorRef<char, Memory>{memory}};
  if (options.stdin_text) {
    input.resize(max_input_bytes + 1);
    const auto count = std::fread(input.data(), 1, input.size(), stdin);
    if (count > max_input_bytes) {
      throw Failure{"send-keys needs text of 1 to 65536 bytes, or --stdin"};
    }

    input.resize(count);
    while (!input.empty() && (input.back() == '\r' || input.back() == '\n')) {
      input.pop_back();
    }

    if (input.empty()) {
      throw Failure{"send-keys needs text of 1 to 65536 bytes, or --stdin"};
    }

    // Zig passes a zero-terminated pointer to sendText, so embedded NUL ends it.
    options.text = std::string_view{input}.substr(0, input.find('\0'));
  }

  if (options.action == "list" || options.action == "get") {
    inspectPanes(memory, paths.socket.c_str(), options, out);
    return 0;
  }

  const auto wanted = paneId(options.target);
  if (options.action == "watch") {
    const auto catalog = paneCatalog(memory, paths.socket.c_str(), options);
    for (const auto &entry : catalog) {
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
    for (const auto &agent : snapshot.entries) {
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
    validateBytes(options.text, max_input_bytes, false);
    session.template exchange<RequestCompleted>(SendPaneText{.pane_id = wanted, .pane_generation = generation, .mode = PaneTextMode::raw, .text = options.text});
    if (options.enter) {
      std::this_thread::sleep_for(submit_delay);
      session.template exchange<RequestCompleted>(SendPaneText{.pane_id = wanted, .pane_generation = generation, .mode = PaneTextMode::raw_enter});
    }
  } else if (options.action == "search") {
    const auto reply = session.template exchange<PaneMatches>(SearchPane{.pane_id = wanted, .needle = options.text});
    if (reply.pane_id != wanted) {
      throw Failure{"unexpected reply from the runtime"};
    }

    if (options.json) {
      out.text("{\"pane_id\":").number(wanted).text(",\"truncated\":").boolean(reply.truncated).text(",\"matches\":[");
    }

    bool first = true;
    for (const auto &match : reply.matches) {
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

template <Allocator Memory>
int runPane(Memory &memory, const pane_agents::Options &options) {
  using namespace pane_agents;
  const RuntimePaths paths{memory, socketOptions(options.socket), ProcessEnvironment{}};
  connectRuntime(memory, paths, options.action == "read" || options.action == "send-keys" || options.action == "focus");
  Output out{memory};
  try {
    const auto result = executePane(memory, paths, options, out);
    out.flush();
    return result;
  } catch (const std::exception &error) {
    out.flush();
    return commandFailure("telar pane", error);
  }
}

}
}

// Interface: project_setup.cppm
export {
namespace telar::runtime::cli::project_setup {

inline constexpr std::size_t max_recipe_bytes = 32 * 1024;
inline constexpr std::chrono::seconds wait_timeout{600};

struct Options {
  std::string_view cwd;
  bool detach = false;

  inline static Options parse(Arguments words) {
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
};

// The shared JSON parser intentionally has one generic syntax error. A recipe
// keeps Zig's distinct EOF diagnostic when its valid prefix can be completed.
template <Allocator Memory>
const char *recipeJsonFailure(Memory &memory, std::string_view text) {
  std::string closing;
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
      closing += byte == '{' ? '}' : ']';
    } else if (byte == '}' || byte == ']') {
      if (closing.empty() || closing.back() != byte) {
        return "SyntaxError";
      }

      closing.pop_back();
    }
  }

  std::reverse(closing.begin(), closing.end());
  constexpr std::array completions{"", "\"", "0", "null", ":null", "\":null", "\"\":null", "n\"", "0\"", "00\"", "000\"", "0000\"", "rue", "ue", "e", "alse", "lse", "se", "ull", "ll", "l"};
  for (const std::string_view suffix : completions) {
    if (suffix.empty() && closing.empty()) {
      continue;
    }

    std::string candidate{text};
    candidate += suffix;
    candidate += closing;
    try {
      const auto completed = JsonValue::parse(candidate);
      const char *diagnostic = "UnexpectedEndOfInput";
      if (completed.encoded().starts_with('{')) {
        completed.eachMember([&](JsonValue key, JsonValue value) {
          String<Memory> name{AllocatorRef<char, Memory>{memory}};
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
    } catch (const std::exception &) {
    }
  }

  return "SyntaxError";
}

template <Allocator Memory>
std::vector<std::string> recipeArguments(Memory &memory, std::string_view text) {
  auto recipe = [&] {
    try {
      return JsonNode<Memory>::parse(memory, text);
    } catch (const std::exception &error) {
      if (std::string_view{error.what()} == "Duplicate JSON field") {
        throw std::runtime_error{"DuplicateField"};
      }

      throw std::runtime_error{recipeJsonFailure(memory, text)};
    }
  }();
  if (recipe.kind() != JsonKind::object) {
    throw std::runtime_error{"UnexpectedToken"};
  }

  const auto *version = recipe.find("version");
  const auto *argv = recipe.find("argv");
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

  std::vector<std::string> result;
  result.reserve(argv->children().size());
  for (const auto &argument : argv->children()) {
    if (argument.kind() != JsonKind::string) {
      throw std::runtime_error{"UnexpectedToken"};
    }

    result.emplace_back(argument.text());
  }

  return result;
}

template <Allocator Memory>
std::optional<std::vector<std::string>> loadRecipe(Memory &memory, std::string_view cwd, bool authorized) {
  const auto path = std::string{cwd} + "/.telar/setup.json";
  FileDescriptor parent;
  FileDescriptor file;
  try {
    parent = file_transfer::openParent(path);
    file = file_transfer::openRegular(parent.get(), "setup.json");
  } catch (const std::runtime_error &error) {
    if (std::string_view{error.what()} == "FileNotFound") {
      return std::nullopt;
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

  std::string text;
  text.reserve(static_cast<std::size_t>(inode.st_size));
  std::array<char, max_recipe_bytes> bytes;
  for (;;) {
    const auto count = ::read(file.get(), bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw std::runtime_error{file_transfer::fileError(errno)};
    }

    if (count == 0) {
      break;
    }

    if (text.size() + static_cast<std::size_t>(count) > max_recipe_bytes) {
      throw std::runtime_error{"StreamTooLong"};
    }

    text.append(bytes.data(), static_cast<std::size_t>(count));
  }

  return recipeArguments(memory, text);
}

template <Allocator Memory>
void awaitSetup(ControlSession<Memory> &session, ExecutionRequest request, ExecutionReply reply) {
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

// worktree create can use the same authorization gate and execution semantics.
template <Allocator Memory>
std::optional<std::uint64_t> prepare(Memory &memory, std::string_view cwd, bool authorized, bool detach, std::string_view socket) {
  const auto recipe = loadRecipe(memory, cwd, authorized);
  if (!recipe) {
    return std::nullopt;
  }

  ServerOptions server_options{};
  server_options.socket = socket;
  const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
  ensureRuntime(memory, paths);
  ControlSession session{memory, paths.socket.c_str()};
  session.receiveTimeout(30);
  std::array<std::string_view, ExecutionOptions::max_arguments> argv;
  for (std::size_t index = 0; index < recipe->size(); ++index) {
    argv[index] = (*recipe)[index];
  }

  const auto id = randomIdentity();
  ExecutionRequest request{.action = ExecutionAction::start, .execution_id = id, .cwd = cwd, .arguments = std::span{argv}.first(recipe->size())};
  writeText(std::format("telar project: setup execution {}; each explicit invocation repeats the recipe\n", id), STDERR_FILENO);
  const auto reply = execution::exchange(session, request);
  if (!detach) {
    awaitSetup(session, request, reply);
  }

  return id;
}

template <Allocator Memory>
int run(Memory &memory, const Options &options) {
  try {
    const auto id = prepare(memory, options.cwd, true, options.detach, {});
    writeText(std::format("{{\"execution_id\":{},\"environment\":{},\"ready\":{}}}\n", id ? std::to_string(*id) : "null", quoteJson(!id ? "not_declared" : options.detach ? "running"
                                                                                                                                                                          : "ready"),
                          jsonBoolean(id && !options.detach)));
    return 0;
  } catch (const std::exception &error) {
    writeText("telar project: " + std::string{error.what()} + "; inspect the execution output, supply missing tools/access on this destination, then explicitly retry project setup\n", STDERR_FILENO);
    return 1;
  }
}

}
}
