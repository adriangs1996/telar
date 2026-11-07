module;
#include "telar_platform/trace_macro.hpp"
#include <utility>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <type_traits>
#include <cstdio>
#include <bit>
#include <stdlib.h>

#include <exception>
#include <charconv>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <cerrno>
#include <unistd.h>

#include <array>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <algorithm>

#include <concepts>
#include <limits>

#include <dirent.h>
#include <cstdlib>
#include <openssl/md5.h>

#include <chrono>

#include <cstddef>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <variant>
#include <stdexcept>

#include <cassert>
#include <sys/types.h>
#include <atomic>
#include <poll.h>
#include <sys/wait.h>

export module telar.cli.hook;

export import telar.cli.hooks.command;
export import telar.platform;


export import telar.cli.hooks.session;


export import telar.base.text;


export import telar.base.memory;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: hooks/input.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
class Input {
public:
  static constexpr std::size_t maximum_bytes = 16 * 1024 * 1024;

  inline explicit Input(Memory &memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  inline void read(int descriptor) {
    TELAR_TRACE("hooks.readInput");
    std::array<char, 4096> buffer;
    for (;;) {
      const auto count = ::read(descriptor, buffer.data(), buffer.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0) {
        throw SystemError{"Read hook input"};
      }
      if (count == 0) {
        break;
      }

      received_ += static_cast<std::size_t>(count);
      text_.append(buffer.data(), std::min(static_cast<std::size_t>(count), maximum_bytes - text_.size()));
    }

    if (limited()) {
      keepWholeMembers();
    }
  }

  inline bool limited() const noexcept { return received_ > maximum_bytes; }
  inline std::uint64_t received() const noexcept { return received_; }
  inline std::string_view text() const noexcept { return text_; }

private:
  inline void keepWholeMembers() {
    const auto opening = text_.find_first_not_of(" \r\n\t");
    if (opening == std::string_view::npos || text_[opening] != '{') {
      text_ = "{}";
      return;
    }

    std::size_t depth = 0;
    std::size_t complete = 0;
    std::size_t member_start = opening + 1;
    String<Memory> candidate{text_.get_allocator()};
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
      text_ = "{}";
    } else {
      text_.resize(complete);
      text_.push_back('}');
    }
  }

  inline bool completeMember(std::size_t start, std::size_t end, String<Memory> &candidate) {
    if (std::string_view{text_.data() + start, end - start}.find_first_not_of(" \r\n\t") == std::string_view::npos) {
      return false;
    }

    candidate = "{";
    candidate.append(text_.data() + start, end - start);
    candidate += "}";
    try {
      JsonValue::parse(candidate);
      validateUnicodeEscapes(candidate.get_allocator().memory(), candidate);
      return true;
    } catch (const JsonError &) {
      return false;
    }
  }

  String<Memory> text_;
  std::uint64_t received_ = 0;
};

template <Allocator Memory>
Input(Memory &memory) -> Input<Memory>;

}
}

// Interface: hooks/lifecycle.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
std::optional<ReportAgent> claudeLifecycle(Payload<Memory> &input, FixedText<96> &event) {
  const auto name = input.event();
  if (input.subagent()) {
    return name == "PreToolUse" || name == "PostToolUse" ? std::optional{ReportAgent{.state = AgentReportState::continuing}} : std::nullopt;
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
      return std::nullopt;
    }
  } else {
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> codexLifecycle(Payload<Memory> &input, FixedText<96> &event, std::string_view database) {
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

    return std::nullopt;
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
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> piLifecycle(Payload<Memory> &input) {
  const auto name = input.event();
  ReportAgent report{.session = sessionReference(input.session())};
  if (name == "session_start" || name == "agent_settled" || name == "ui_prompt_end" || name == "state_snapshot") {
    const bool idle = input.fields.boolean("idle").value_or(name == "session_start" || name == "agent_settled");
    report.state = idle ? AgentReportState::ready : AgentReportState::working;
    if (input.fields.boolean("blocked").value_or(false)) {
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
    return std::nullopt;
  }

  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> openCodeLifecycle(Payload<Memory> &input, FixedText<96> &event) {
  const auto name = input.event();
  const auto blocked = input.blockedReason();
  ReportAgent report{.session = sessionReference(input.session())};
  if (name == "tool.execute.before") {
    if (blocked != AgentBlockedReason::none) {
      return std::nullopt;
    }

    report.state = AgentReportState::working;
    toolEvent(event, input);
  } else if (name == "load" || name == "chat.message" || name == "session.status" || name == "permission.asked" || name == "question.asked" || name == "permission.replied" || name == "question.replied" || name == "question.rejected" || name == "state_snapshot") {
    report.state = input.fields.boolean("busy").value_or(false) ? AgentReportState::working : AgentReportState::ready;
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
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> cursorLifecycle(Payload<Memory> &input, FixedText<96> &event, std::string_view metadata) {
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
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

}
}

// Interface: hooks/progress.cppm
export {
namespace telar::runtime::cli::hooks {

inline std::optional<AgentPlanStatus> planStatus(std::string_view text) noexcept {
  constexpr std::array names{"pending", "in_progress", "completed", "deleted"};
  const auto found = std::ranges::find(names, text);
  return found == names.end() ? std::nullopt : std::optional{static_cast<AgentPlanStatus>(found - names.begin())};
}

template <Allocator Memory>
void setPlan(Payload<Memory> &input, Reports &reports, ReportAgentProgress &report) {
  const bool todo = input.fields.text("tool_name") == "TodoWrite";
  const auto items = input.tools.value(todo ? "todos" : "plan");
  if (!items || !items->encoded().starts_with('[')) {
    return;
  }

  String<Memory> current{AllocatorRef<char, Memory>{input.memory}};
  String<Memory> pending{AllocatorRef<char, Memory>{input.memory}};
  items->eachElement([&](JsonValue value) {
    if (!value.encoded().starts_with('{')) {
      return;
    }

    Object item{input.memory, value};
    const auto status = planStatus(item.stringField("status").value_or("pending")).value_or(AgentPlanStatus::pending);
    if (status == AgentPlanStatus::deleted) {
      return;
    }

    report.plan_total += report.plan_total < UINT16_MAX;
    if (status == AgentPlanStatus::completed) {
      report.plan_done += report.plan_done < UINT16_MAX;
    } else if (status == AgentPlanStatus::in_progress && current.empty()) {
      current = item.stringField(todo ? "activeForm" : "step").value_or(item.stringField(todo ? "content" : "step").value_or(""));
    } else if (status == AgentPlanStatus::pending && pending.empty()) {
      pending = item.stringField(todo ? "content" : "step").value_or("");
    }
  });

  report.plan_op = AgentPlanOp::set;
  displayText(reports.step, current.empty() ? std::string_view{pending} : std::string_view{current}, false);
  report.plan_text = reports.step.view();
}

template <Allocator Memory>
void updatePlan(Payload<Memory> &input, Reports &reports, ReportAgentProgress &report) {
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
    const auto status = planStatus(input.tools.stringField("status").value_or(""));
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

template <Allocator Memory>
std::optional<ReportAgentProgress> progressReport(Payload<Memory> &input, Reports &reports) {
  if ((input.provider != AgentProvider::claude && input.provider != AgentProvider::codex) || input.subagent()) {
    return std::nullopt;
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
      } catch (const EncodingError &) {
      }
    }
  }

  updatePlan(input, reports, report);
  if (input.event() == "Stop") {
    displayText(reports.message, input.fields.optionalText("last_assistant_message").value_or(""), true);
    report.final_message = reports.message.view();
  }

  return report.cwd.empty() && report.plan_op == AgentPlanOp::none && report.final_message.empty() ? std::nullopt : std::optional{report};
}

}
}

// Interface: hooks/session_files.cppm
export {
namespace telar::runtime::cli::hooks {

class SessionFiles {
public:
  template <EnvironmentLookup Environment>
  inline std::string_view codex(const Environment &environment) noexcept {
    try {
      const auto override = environment.lookup("CODEX_HOME");
      const auto home = override.empty() ? join(environment.lookup("HOME"), ".codex", root_) : copy(override, root_);
      if (!home) {
        return {};
      }

      DirectoryStream directory{FileDescriptor{::open(home->data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      std::optional<std::uint32_t> best;
      while (const auto *entry = directory.next()) {
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

      std::array<char, 32> filename;
      const auto length = std::snprintf(filename.data(), filename.size(), "state_%u.sqlite", *best);
      return join(*home, {filename.data(), static_cast<std::size_t>(length)}, path_).value_or("");
    } catch (const std::exception &) {
      return {};
    }
  }

  template <Allocator Memory, EnvironmentLookup Environment>
  inline std::string_view cursor(Payload<Memory> &input, const Environment &environment) noexcept {
    try {
      if (input.event() != "sessionStart" && input.event() != "beforeSubmitPrompt") {
        return {};
      }

      const auto chat = input.session();
      if (chat.empty() || chat.size() > 64 || !std::ranges::all_of(chat, [](unsigned char byte) { return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-'; })) {
        return {};
      }

      const auto root = cursorRoot(environment);
      if (!root) {
        return {};
      }

      if (!input.workspace().empty()) {
        std::array<unsigned char, MD5_DIGEST_LENGTH> digest;
        MD5(reinterpret_cast<const unsigned char *>(input.workspace().data()), input.workspace().size(), digest.data());
        constexpr std::string_view digits = "0123456789abcdef";
        std::array<char, 32> encoded;
        for (std::size_t index = 0; index < digest.size(); ++index) {
          encoded[2 * index] = digits[digest[index] >> 4];
          encoded[2 * index + 1] = digits[digest[index] & 15];
        }
        if (const auto path = cursorPath(*root, {encoded.data(), encoded.size()}, chat)) {
          return *path;
        }
      }

      const auto chats = join(*root, "chats", path_);
      if (!chats) {
        return {};
      }

      DirectoryStream directory{FileDescriptor{::open(chats->data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      constexpr std::size_t maximum_directories = 4096;
      for (std::size_t count = 0; count < maximum_directories; ++count) {
        const auto *entry = directory.next();
        if (entry == nullptr) {
          break;
        }
        if (entry->d_type == DT_DIR && std::strlen(entry->d_name) == 32) {
          if (const auto path = cursorPath(*root, {entry->d_name, std::strlen(entry->d_name)}, chat)) {
            return *path;
          }
        }
      }
    } catch (const std::exception &) {
    }

    return {};
  }

private:
  template <EnvironmentLookup Environment>
  inline std::optional<std::string_view> cursorRoot(const Environment &environment) {
    if (const auto configured = environment.lookup("CURSOR_CONFIG_DIR"); !configured.empty()) {
      return copy(configured, root_);
    }
    if (const auto xdg = environment.lookup("XDG_CONFIG_HOME"); !xdg.empty()) {
      return join(xdg, "cursor", root_);
    }

    return join(environment.lookup("HOME"), ".cursor", root_);
  }

  inline std::optional<std::string_view> cursorPath(std::string_view root, std::string_view digest, std::string_view chat) {
    const auto length = std::snprintf(path_.data(), path_.size(), "%.*s/chats/%.*s/%.*s/meta.json", static_cast<int>(root.size()), root.data(), static_cast<int>(digest.size()), digest.data(), static_cast<int>(chat.size()), chat.data());
    if (length < 0 || static_cast<std::size_t>(length) >= path_.size()) {
      return std::nullopt;
    }

    struct stat status;
    return ::lstat(path_.data(), &status) == 0 && S_ISREG(status.st_mode) ? std::optional{std::string_view{path_.data(), static_cast<std::size_t>(length)}} : std::nullopt;
  }

  inline static std::optional<std::string_view> copy(std::string_view value, std::span<char> buffer) noexcept {
    if (value.empty() || value.size() >= buffer.size() || value.contains('\0')) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), value.data(), value.size());
    buffer[value.size()] = '\0';
    return std::string_view{buffer.data(), value.size()};
  }

  inline static std::optional<std::string_view> join(std::string_view root, std::string_view suffix, std::span<char> buffer) noexcept {
    return root.empty() ? std::nullopt : GitFiles::join(root, suffix, buffer);
  }

  std::array<char, PATH_MAX> root_;
  std::array<char, PATH_MAX> path_;
};

}
}

// Interface: hooks/map.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
std::optional<ReportAgentTitle> titleReport(Payload<Memory> &input) {
  std::optional<std::string_view> title;
  if (input.provider == AgentProvider::claude) {
    if (input.event() == "SessionStart" && !input.fields.optionalText("agent_id").has_value() && !input.fields.text("session_title").empty()) {
      title = input.fields.text("session_title");
    }
  } else if (input.provider == AgentProvider::pi) {
    if (input.event() == "session_info_changed") {
      title = input.fields.optionalText("name").value_or("");
    } else if (input.event() == "session_start") {
      title = input.fields.optionalText("name");
    }
  } else if (input.provider == AgentProvider::opencode && input.event() == "session.updated") {
    title = input.fields.optionalText("title");
    if (title && defaultOpenCodeTitle(*title)) {
      title = "";
    }
  }

  return title ? std::optional{ReportAgentTitle{.title = utf8Prefix(*title, 96)}} : std::nullopt;
}

template <Allocator Memory, EnvironmentLookup Environment>
void map(Payload<Memory> &input, Reports &reports, SessionFiles &files, const Environment &environment) {
  TELAR_TRACE("hooks.mapReports");
  reports.command = commandReport(input);
  reports.title = titleReport(input);
  reports.progress = progressReport(input, reports);
  switch (input.provider) {
  case AgentProvider::claude:
    reports.lifecycle = claudeLifecycle(input, reports.event);
    break;
  case AgentProvider::codex: {
    if (input.event() == "Stop" || input.event() == "Interrupt" || input.event() == "SubagentStop") {
      CodexSubagents children;
      children.read(input.fields.text("transcript_path"));
      input.running_subagents = children.countExcept(input.fields.optionalText("agent_id").value_or(""));
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

}
}

// Interface: hooks/target.cppm
export {
namespace telar::runtime::cli::hooks {

inline std::optional<std::uint64_t> unsignedValue(std::string_view value) noexcept {
  return unsignedDecimal<std::uint64_t>(value);
}

template <EnvironmentLookup Environment>
std::optional<PaneTarget> paneTarget(const Environment &environment, AgentProvider provider) noexcept {
  const auto pane = unsignedValue(environment.lookup("TELAR_PANE_ID"));
  const auto generation = unsignedValue(environment.lookup("TELAR_PANE_GENERATION"));
  if (!pane || *pane == 0 || !generation) {
    return std::nullopt;
  }

  return PaneTarget{.pane_id = *pane, .generation = *generation, .provider = provider};
}

}
}

// Interface: hooks/worktrees.cppm
export {
namespace telar::runtime::cli::hooks {

inline bool validWorktreeBranch(std::string_view branch) noexcept {
  if (branch.empty() || branch.size() > 200 || branch.front() == '-' || branch.front() == '.' || branch.contains("..")) {
    return false;
  }

  try {
    validateUtf8(branch);
  } catch (const EncodingError &) {
    return false;
  }

  return std::ranges::none_of(branch, [](unsigned char byte) { return byte <= ' ' || byte == 0x7f || byte == '~' || byte == '^' || byte == ':'; });
}

template <Allocator Memory, EnvironmentLookup Environment>
class Worktrees {
public:
  inline explicit Worktrees(Memory &memory, const Environment &environment, std::string_view socket)
      : memory_(memory), environment_(environment), socket_(socket), output_(memory, maximum_output_bytes), root_(AllocatorRef<char, Memory>{memory}), branch_(AllocatorRef<char, Memory>{memory}), base_(AllocatorRef<char, Memory>{memory}), path_(AllocatorRef<char, Memory>{memory}) {}

  inline void answer(Object<Memory> &input) {
    TELAR_TRACE("hooks.worktree");
    if (input.text("hook_event_name") == "WorktreeCreate") {
      create(input);
    } else {
      remove(input);
    }
  }

private:
  inline std::string_view git(std::initializer_list<std::string_view> arguments, const char *failure) {
    if (std::ranges::any_of(arguments, [](std::string_view argument) { return argument.contains('\0'); })) {
      throw std::runtime_error{failure};
    }

    Command command{memory_, Launch{.arguments = {arguments.begin(), arguments.size()}}, CommandPurpose::configured_helper};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{300};
    const bool mutation = std::ranges::find(arguments, "worktree") != arguments.end();
    if (mutation) {
      RetainedStream diagnostics{memory_, maximum_output_bytes};
      const auto status = output_.streamDiagnostics(command, deadline, [](std::span<const Byte>) { return true; }, [&](std::span<const Byte> bytes) { diagnostics.append(bytes); });
      if (status != 0) {
        std::array<Byte, maximum_output_bytes> buffer;
        const auto kept = diagnostics.read(diagnostics.retainedOffset(), buffer);
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

    return GitFiles::trim(output_.text(), " \r\n");
  }

  inline void mainRoot(std::string_view directory) {
    auto common = git({"git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"}, "NotARepository");
    while (common.ends_with('/')) {
      common.remove_suffix(1);
    }
    if (!common.starts_with('/') || !common.ends_with("/.git")) {
      throw std::runtime_error{"NotARepository"};
    }

    root_ = common.substr(0, common.size() - 5);
  }

  inline void chooseBranch(std::string_view name) {
    branch_ = name;
    if (validWorktreeBranch(branch_)) {
      return;
    }

    branch_.resize(std::min<std::size_t>(branch_.size(), 200));
    for (auto &character : branch_) {
      const auto byte = static_cast<unsigned char>(character);
      const bool safe = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '/';
      if (!safe) {
        character = '-';
      }
    }

    branch_ = GitFiles::trim(branch_, "-./");
    if (!validWorktreeBranch(branch_)) {
      throw std::runtime_error{"InvalidWorktreeBranch"};
    }
  }

  inline void create(Object<Memory> &input) {
    std::array<char, PATH_MAX> current;
    auto cwd = input.text("cwd");
    if (cwd.empty()) {
      if (::getcwd(current.data(), current.size()) == nullptr) {
        throw SystemError{"Read working directory"};
      }

      cwd = current.data();
    }

    mainRoot(cwd);
    chooseBranch(input.text("name"));
    base_ = git({"git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"}, "NotARepository");
    if (!validWorktreeBranch(base_)) {
      throw std::runtime_error{"InvalidWorktreeBranch"};
    }

    path_ = root_;
    path_ += "-worktrees/";
    const auto suffix = path_.size();
    path_ += branch_;
    std::replace(path_.begin() + suffix, path_.end(), '/', '-');
    std::replace(path_.begin() + suffix, path_.end(), '\\', '-');
    String<Memory> reference{"refs/heads/", AllocatorRef<char, Memory>{memory_}};
    reference += branch_;
    bool exists = true;
    try {
      git({"git", "-C", root_, "show-ref", "--verify", "--quiet", reference}, "branch unavailable");
    } catch (const std::exception &) {
      exists = false;
    }

    if (exists) {
      git({"git", "-C", root_, "worktree", "add", "--", path_, branch_}, "WorktreeAddFailed");
    } else {
      git({"git", "-C", root_, "worktree", "add", "-b", branch_, "--", path_, base_}, "WorktreeAddFailed");
    }

    try {
      registerWorktree();
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar hook: worktree created but not tracked: %s\n", error.what());
    }

    std::printf("%s\n", path_.c_str());
  }

  inline RuntimePaths<Memory> paths() {
    ServerOptions options;
    options.socket = socket_;
    return RuntimePaths{memory_, options, environment_};
  }

  inline void registerWorktree() {
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
    Session session{memory_, resolved.socket.c_str(), *target};
    session.template exchange<WorktreeRegistered>(RegisterWorktree{.source = *workspace, .created_by = target->pane_id, .path = path_, .branch = branch_, .base = base_});
  }

  inline void remove(Object<Memory> &input) {
    path_ = input.text("worktree_path");
    if (!path_.starts_with('/') || path_.contains('\0')) {
      throw std::runtime_error{"InvalidWorktreePath"};
    }

    if (const auto pane = unsignedValue(environment_.lookup("TELAR_PANE_ID")); pane) {
      try {
        forgetWorktree();
      } catch (const std::exception &) {
      }
    }

    mainRoot(path_);
    try {
      git({"git", "-C", root_, "worktree", "remove", "--", path_}, "git worktree remove failed");
    } catch (const std::exception &) {
      std::fprintf(stderr, "telar hook: kept %s; it has changes to review\n", path_.c_str());
    }
  }

  inline void forgetWorktree() {
    const auto resolved = paths();
    RuntimeConnection connection{resolved.socket.c_str()};
    connection.receiveTimeout(30);
    Vector<Byte, Memory> incoming{AllocatorRef<Byte, Memory>{memory_}};
    Vector<Byte, Memory> decoded{AllocatorRef<Byte, Memory>{memory_}};
    incoming.resize(max_payload_size);
    decoded.resize(max_payload_size);
    std::array<Byte, 64> outgoing;
    std::uint64_t identity = 0;
    while (identity == 0) {
      randomBytes(&identity, sizeof(identity));
    }

    connection.send(RequestRuntimeState{.client_identity = identity, .interactive = false}, outgoing);
    for (;;) {
      const auto frame = connection.receive(incoming);
      if (frame.front() == static_cast<Byte>(ServerTag::workspace_list)) {
        DecodeStorage storage{decoded};
        const auto catalog = Codec::decode<WorkspaceList>(frame, storage);
        for (const auto &worktree : catalog.worktrees) {
          if (worktree.path == path_) {
            connection.send(ForgetWorktree{.request_id = 1, .worktree = worktree.worktree}, outgoing);
            waitForgotten(connection, incoming);
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

  inline static void waitForgotten(RuntimeConnection &connection, std::span<Byte> incoming) {
    for (;;) {
      const auto frame = connection.receive(incoming);
      if (frame.front() == static_cast<Byte>(ServerTag::request_completed) || frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
        return;
      }
    }
  }

  static constexpr std::size_t maximum_output_bytes = 64 * 1024;
  Memory &memory_;
  const Environment &environment_;
  std::string_view socket_;
  CommandOutput<Memory> output_;
  String<Memory> root_;
  String<Memory> branch_;
  String<Memory> base_;
  String<Memory> path_;
};

template <Allocator Memory, EnvironmentLookup Environment>
Worktrees(Memory &memory, const Environment &environment, std::string_view socket) -> Worktrees<Memory, Environment>;

template <Allocator Memory, EnvironmentLookup Environment>
std::optional<int> answerWorktree(Memory &memory, const Environment &environment, Object<Memory> &fields, std::string_view socket) {
  try {
    for (const auto name : {"hook_event_name", "cwd", "name", "worktree_path"}) {
      fields.text(name);
    }

    const auto event = fields.text("hook_event_name");
    if (event == "WorktreeCreate" || event == "WorktreeRemove") {
      try {
        Worktrees{memory, environment, socket}.answer(fields);
        return 0;
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar hook: %.*s failed: %s\n", static_cast<int>(event.size()), event.data(), error.what());
        return 1;
      }
    }
  } catch (const std::exception &) {
  }

  return std::nullopt;
}

}
}

// Interface: hook.cppm
export {
namespace telar::runtime::cli {

template <Allocator Memory, EnvironmentLookup Environment>
int runHook(Memory &memory, const HookOptions &options, const Environment &environment) noexcept {
#if TELAR_DEBUG
  std::optional<trace::Session<Memory>> tracing;
  try {
    const String<Memory> path{environment.lookup("TELAR_HOOK_TRACE"), AllocatorRef<char, Memory>{memory}};
    if (!path.empty()) {
      tracing.emplace(memory, path.c_str());
    }
  } catch (const std::exception &) {
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
    const auto worktree_status = options.provider == AgentProvider::claude ? hooks::answerWorktree(memory, environment, fields, options.socket) : std::nullopt;
    status = worktree_status.value_or(0);
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
        hooks::Session session{memory, paths.socket.c_str(), *target};
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
  } catch (const std::exception &) {
  }

  if (input.limited()) {
    std::fprintf(stderr, "telar: Limit reached: hooks.max_input_bytes: %llu bytes; limit %zu\n", static_cast<unsigned long long>(input.received()), input.maximum_bytes);
  }

  return status;
}

}
}
