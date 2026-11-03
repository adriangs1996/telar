#pragma once

#include "control_session.hpp"
#include "json_text.hpp"
#include "pane_agent_options.hpp"
#include "server.hpp"
#include <chrono>
#include <thread>

namespace telar::runtime::cli::pane_agents {

inline constexpr auto poll_interval = std::chrono::milliseconds{250};
inline constexpr auto submit_delay = std::chrono::milliseconds{150};
inline constexpr auto start_grace = std::chrono::seconds{5};
inline constexpr auto interrupt_settle = std::chrono::seconds{15};

class Failure : public std::runtime_error {
public:
  explicit Failure(const char *message, int status = 1)
      : std::runtime_error{message},
        status(status) {}

  int status;
};

inline std::uint64_t current(const char *name, bool nonzero = false) {
  const auto text = ProcessEnvironment{}.lookup(name);
  const auto id = targetNumber(text);
  if (!id || (nonzero && *id == 0)) {
    throw Failure{missing_pane_context};
  }

  return *id;
}

inline std::uint64_t paneId(std::string_view target) {
  if (target == "--current") {
    return current("TELAR_PANE_ID");
  }

  if (const auto id = targetNumber(target)) {
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

template <Allocator Memory>
void ensureRuntime(Memory &memory, const RuntimePaths<Memory> &paths, bool start) {
  std::optional<RuntimeConnection> probe;
  if (connectExisting(probe, paths.socket.c_str())) {
    return;
  }

  if (!start) {
    throw Failure{"the local runtime is not reachable"};
  }

  paths.prepareSocket();
  const auto pid = launchDaemon(memory, ServerOptions{}, paths, ExecutablePath{runtime_program});
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  while (!connectExisting(probe, paths.socket.c_str())) {
    int status = 0;
    if (::waitpid(pid, &status, WNOHANG) == pid || std::chrono::steady_clock::now() >= deadline) {
      throw Failure{"the local runtime is not reachable"};
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{10});
  }
}

template <Allocator Memory>
class Output {
public:
  explicit Output(Memory &memory)
      : data(AllocatorRef<char, Memory>{memory}) {}

  Output &text(std::string_view value) {
    data.append(value);
    return *this;
  }

  template <typename Integer>
  Output &number(Integer value) {
    std::array<char, 32> buffer;
    const auto end = std::to_chars(buffer.data(), buffer.data() + buffer.size(), value).ptr;
    data.append(buffer.data(), end);
    return *this;
  }

  Output &boolean(bool value) {
    return text(value ? "true" : "false");
  }

  Output &json(std::string_view value, JsonEscapes escapes = JsonEscapes::control) {
    appendJsonText(data, value, escapes);
    return *this;
  }

  void flush() {
    std::fwrite(data.data(), 1, data.size(), stdout);
    std::fflush(stdout);
    data.clear();
  }

  String<Memory> data;
};

template <Allocator Memory>
void writeAgent(Output<Memory> &out, const AgentSnapshotEntry &agent, bool json) {
  const auto provider = agent.provider_name.empty() ? std::string_view{"unknown"} : agent.provider_name;
  const auto status = status_names[static_cast<std::size_t>(agent.status)];
  if (json) {
    out.text("{\"pane_id\":").number(agent.pane_id).text(",\"pane_generation\":").number(agent.pane_generation).text(",\"workspace_id\":").number(agent.location.workspace.id).text(",\"tab_id\":").number(agent.location.tab_id).text(",\"pane_index\":").number(agent.pane_index).text(",\"provider\":").json(provider).text(",\"provider_index\":").number(static_cast<unsigned>(agent.provider)).text(",\"status\":").json(status);
    out.text(",\"workspace\":").json(agent.workspace_label).text(",\"tab\":").json(agent.tab_label).text(",\"title\":").json(agent.session_title).text(",\"cwd\":").json(agent.cwd_label).text(",\"blocked_reason\":").json(blocked_reasons[static_cast<std::size_t>(agent.blocked_reason)]).text(",\"status_age_s\":").number(agent.status_age_s).text(",\"worktree_id\":").number(agent.work_tree).text(",\"last_event\":").json(agent.last_event);
    out.text(",\"plan\":{\"done\":").number(agent.plan_done).text(",\"total\":").number(agent.plan_total).text(",\"step\":").json(agent.plan_step).text("},\"final_message\":").json(agent.final_message).text(",\"session_id\":\"");
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

    out.text(",\"text\":").json(reply.text).text("}\n");
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
  const auto wanted = target == "--current" ? std::optional{current("TELAR_PANE_ID")} : targetNumber(target);
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
  const auto id = targetNumber(environment.lookup("TELAR_PANE_ID"));
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

inline int commandFailure(const char *family, const std::exception &error, bool routed = false) {
  const auto *system = dynamic_cast<const SystemError *>(&error);
  const auto socket_timeout = dynamic_cast<const SocketError *>(&error) && (errno == EAGAIN || errno == EWOULDBLOCK);
  const auto timeout = socket_timeout || (system && (system->code() == EAGAIN || system->code() == EWOULDBLOCK));
  const char *prefix = routed ? "telar" : family;
  std::fprintf(stderr, "%s: %s\n", prefix, timeout ? "RuntimeTimeout" : error.what());
  if (timeout) {
    return routed ? 3 : 1;
  }

  if (const auto *failure = dynamic_cast<const Failure *>(&error)) {
    return failure->status;
  }

  if (const auto *failure = dynamic_cast<const ControlFailure *>(&error)) {
    return !routed && (failure->code() == FailureCode::pane_not_found || failure->code() == FailureCode::pane_exited || (std::string_view{family} == "telar agent" && failure->code() == FailureCode::worktree_not_found)) ? 2 : 1;
  }

  return 1;
}

}
