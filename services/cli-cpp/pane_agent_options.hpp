#pragma once

#include "arguments.hpp"
#include "telar_base/text/decimal.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <span>
#include <string>

namespace telar::runtime::cli::pane_agents {

inline constexpr std::size_t max_input_bytes = 65536;
inline constexpr std::uint16_t max_read_rows = 2000;
inline constexpr std::uint32_t max_timeout_seconds = 86400;
inline constexpr std::uint32_t default_interval_ms = 250;
inline constexpr std::uint32_t min_interval_ms = 10;
inline constexpr std::uint32_t max_interval_ms = 60000;

inline constexpr std::array<std::string_view, 4> directions{"left", "right", "up", "down"};
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
  std::optional<ClientAction> routed{};
  std::uint64_t client = 0;
  std::uint64_t target_id = 0;
  std::int64_t value = 0;
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

inline void copyRange(std::string_view text) {
  const auto colon = text.find(':');
  if (colon == std::string_view::npos) {
    usage("InvalidCopyRange");
  }

  for (const auto point : {text.substr(0, colon), text.substr(colon + 1)}) {
    const auto comma = point.find(',');
    if (comma == std::string_view::npos) {
      usage("InvalidCopyRange");
    }

    number<std::uint16_t>(point.substr(0, comma), "InvalidCopyRange");
    number<std::uint32_t>(point.substr(comma + 1), "InvalidCopyRange");
  }
}

inline Options parseRouted(std::span<char *const> words, ClientAction action) {
  Options options{.action = words.front(), .routed = action};
  Cursor cursor{words.subspan(1)};
  if (action != ClientAction::pane_create) {
    options.target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
  }

  if (action == ClientAction::pane_split) {
    options.text = cursor.take("MissingSplitAxis");
    if (options.text != "horizontal" && options.text != "vertical") {
      usage("InvalidSplitAxis");
    }
  } else if (action == ClientAction::pane_resize) {
    options.text = cursor.take("MissingPaneDirection");
    choice<PaneDirection>(options.text, "InvalidPaneDirection", directions);
  } else if (action == ClientAction::pane_copy) {
    options.text = cursor.take("MissingCopyRange");
    copyRange(options.text);
  } else if (action == ClientAction::pane_scroll) {
    options.value = signedNumber<std::int32_t>(cursor.take("MissingScrollDelta"), "InvalidScrollDelta");
  }

  while (const auto word = cursor.next()) {
    const std::string_view arg = *word;
    if (arg == "--client" && options.client == 0) {
      options.client = positive(cursor.take("MissingClientId"), "InvalidTarget");
    } else if (arg == "--json" && !options.json) {
      options.json = true;
    } else if (arg == "--socket" && !options.socket) {
      options.socket = cursor.take("MissingSocketPath").data();
    } else {
      usage("UnknownClientCommandOption");
    }
  }

  if (options.client == 0) {
    usage("MissingClientId");
  }

  return options;
}

inline Options parsePane(std::span<char *const> words) {
  Cursor cursor{words};
  Options options{.action = cursor.take("MissingPaneAction")};
  const auto action = options.action;
  const std::array<std::pair<std::string_view, ClientAction>, 8> routed{{{"create", ClientAction::pane_create}, {"split", ClientAction::pane_split}, {"close", ClientAction::pane_close}, {"focus", ClientAction::pane_focus}, {"resize", ClientAction::pane_resize}, {"fullscreen", ClientAction::pane_fullscreen}, {"scroll", ClientAction::pane_scroll}, {"copy", ClientAction::pane_copy}}};
  for (const auto &[name, route] : routed) {
    if (action == name && !(action == "focus" && (std::find_if(words.begin(), words.end(), [](const char *word) { return std::string_view{word} == "--current" || std::string_view{word} == "--direction"; }) != words.end()))) {
      return parseRouted(words, route);
    }
  }

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
      options.direction = choice<PaneDirection>(cursor.take("UnknownPaneOption"), "InvalidPaneDirection", directions);
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
