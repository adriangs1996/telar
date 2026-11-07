module;
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <new>


#include <cstdint>

#include <cstring>

export module telar.cli.hooks.command;

import std;

export import telar.config;


export import telar.base.text;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: hook_options.cppm
export {
namespace telar::runtime::cli {

struct HookOptions {
  AgentProvider provider;
  std::string_view socket;

  inline static HookOptions parse(std::span<char *const> arguments) {
    if (arguments.empty()) {
      throw std::invalid_argument{"Missing hook agent"};
    }

    std::optional<AgentProvider> provider;
    for (const auto candidate : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
      if (describeProvider(candidate).name == arguments.front()) {
        provider = candidate;
      }
    }
    if (!provider) {
      throw std::invalid_argument{"Unknown hook agent"};
    }

    HookOptions options{.provider = *provider, .socket = {}};
    for (std::size_t index = 1; index < arguments.size(); index += 2) {
      if (std::string_view{arguments[index]} != "--socket" || index + 1 >= arguments.size()) {
        throw std::invalid_argument{"Unknown hook option"};
      }

      options.socket = arguments[index + 1];
    }

    return options;
  }
};

}
}

// Interface: hooks/object.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
class Object {
public:
  inline explicit Object(Memory &memory, JsonValue value, bool reject_duplicates = false)
      : memory_(memory), members_(AllocatorRef<Member, Memory>{memory}), reject_duplicates_(reject_duplicates) {
    if (!value.encoded().starts_with('{')) {
      throw std::invalid_argument{"Expected hook object"};
    }

    value.eachMember([&](JsonValue key, JsonValue entry) {
      String<Memory> name{AllocatorRef<char, Memory>{memory_}};
      key.string(name);
      members_.push_back(Member{.name = std::move(name), .value = entry, .text = std::nullopt, .position = members_.size()});
    });

    indexMembers();
  }

  inline std::optional<JsonValue> value(std::string_view name) const {
    const auto *member = find(name);
    if (member != nullptr) {
      checkUnique(*member);
    }
    return member == nullptr ? std::nullopt : std::optional{member->value};
  }

  inline std::optional<std::string_view> optionalText(std::string_view name) {
    auto *member = find(name);
    if (member == nullptr) {
      return std::nullopt;
    }

    checkUnique(*member);
    if (member->value.encoded() == "null") {
      return std::nullopt;
    }

    return decode(*member);
  }

  inline std::string_view text(std::string_view name) {
    auto *member = find(name);
    return member == nullptr ? std::string_view{} : decode(*member);
  }

  inline std::optional<std::string_view> stringField(std::string_view name) {
    const auto field = value(name);
    return field && field->encoded().starts_with('"') ? optionalText(name) : std::nullopt;
  }

  inline std::optional<bool> boolean(std::string_view name) const {
    const auto field = value(name);
    if (!field || field->encoded() == "null") {
      return std::nullopt;
    }
    if (field->encoded() != "true" && field->encoded() != "false") {
      throw std::invalid_argument{"Expected hook boolean"};
    }

    return field->boolean();
  }

  template <typename Integer>
  inline std::optional<Integer> integer(std::string_view name) {
    const auto field = value(name);
    if (!field || field->encoded() == "null") {
      return std::nullopt;
    }

    const auto input = field->encoded().starts_with('"') ? text(name) : field->encoded();
    Integer result{};
    const auto parsed = std::from_chars(input.data(), input.data() + input.size(), result);
    if (parsed.ec != std::errc{} || parsed.ptr != input.data() + input.size()) {
      throw std::invalid_argument{"Expected hook integer"};
    }

    return result;
  }

  inline void requireUnique() const {
    for (const auto &member : members_) {
      if (member.duplicate) {
        throw std::invalid_argument{"Duplicate hook field"};
      }
    }
  }

  template <typename Consumer>
  inline void eachValue(Consumer &&consume) const {
    for (const auto &member : members_) {
      consume(member.value);
    }
  }

private:
  struct Member {
    String<Memory> name;
    JsonValue value;
    std::optional<String<Memory>> text;
    std::size_t position;
    bool duplicate = false;
  };

  inline Member *find(std::string_view name) noexcept {
    const auto found = std::lower_bound(members_.begin(), members_.end(), name, [](const Member &member, std::string_view key) { return member.name < key; });
    return found != members_.end() && found->name == name ? &*found : nullptr;
  }

  inline const Member *find(std::string_view name) const noexcept {
    return const_cast<Object *>(this)->find(name);
  }

  inline void indexMembers() {
    std::ranges::sort(members_, [](const Member &left, const Member &right) { return left.name == right.name ? left.position < right.position : left.name < right.name; });
    std::size_t unique = 0;
    for (std::size_t index = 0; index < members_.size(); ++index) {
      if (unique != 0 && members_[unique - 1].name == members_[index].name) {
        members_[unique - 1] = std::move(members_[index]);
        members_[unique - 1].duplicate = true;
      } else {
        if (unique != index) {
          members_[unique] = std::move(members_[index]);
        }

        ++unique;
      }
    }

    members_.erase(members_.begin() + unique, members_.end());
  }

  inline std::string_view decode(Member &member) {
    checkUnique(member);
    if (!member.text) {
      String<Memory> decoded{AllocatorRef<char, Memory>{memory_}};
      member.value.string(decoded);
      member.text = std::move(decoded);
    }

    return *member.text;
  }

  inline void checkUnique(const Member &member) const {
    if (reject_duplicates_ && member.duplicate) {
      throw std::invalid_argument{"Duplicate hook field"};
    }
  }

  Memory &memory_;
  Vector<Member, Memory> members_;
  bool reject_duplicates_;
};

template <Allocator Memory>
Object(Memory &memory, JsonValue value, bool reject_duplicates = false) -> Object<Memory>;

}
}

// Interface: hooks/validation.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
void validateUnicodeEscapes(Memory &memory, std::string_view input) {
  if (!input.contains("\\u")) {
    return;
  }

  String<Memory> decoded{AllocatorRef<char, Memory>{memory}};
  std::optional<std::size_t> start;
  for (std::size_t index = 0; index < input.size(); ++index) {
    if (start && input[index] == '\\') {
      ++index;
    } else if (input[index] == '"') {
      if (start) {
        const auto token = input.substr(*start, index - *start + 1);
        if (token.contains("\\u")) {
          JsonValue{token}.string(decoded);
        }

        start.reset();
      } else {
        start = index;
      }
    }
  }
}

template <Allocator Memory>
void validateDynamicValue(Memory &memory, JsonValue value) {
  if (value.encoded().starts_with('{')) {
    Object fields{memory, value};
    fields.requireUnique();
    fields.eachValue([&](JsonValue child) { validateDynamicValue(memory, child); });
  } else if (value.encoded().starts_with('[')) {
    value.eachElement([&](JsonValue child) { validateDynamicValue(memory, child); });
  }
}

}
}

// Interface: hooks/payload.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
class Payload {
public:
  inline explicit Payload(Memory &memory, AgentProvider provider, JsonValue input)
      : Payload(memory, provider, Object<Memory>{memory, input, true}) {}

  inline explicit Payload(Memory &memory, AgentProvider provider, Object<Memory> input)
      : memory(memory), provider(provider), fields(std::move(input)), tools(memory, toolObject(fields)) {
    if (const auto tool_input = fields.value("tool_input")) {
      if (tool_input->encoded().starts_with('{')) {
        tools.requireUnique();
        tools.eachValue([&](JsonValue child) { validateDynamicValue(memory, child); });
      } else {
        validateDynamicValue(memory, *tool_input);
      }
    }

    for (const auto name : {"tool_name", "cwd"}) {
      fields.text(name);
    }

    if (provider == AgentProvider::pi || provider == AgentProvider::opencode) {
      for (const auto name : {"event", "session_id", "tool_call_id"}) {
        fields.text(name);
      }

      fields.template integer<std::int32_t>("exit_code");
      if (provider == AgentProvider::pi) {
        fields.boolean("idle");
        strictBoolean("blocked");
        fields.optionalText("name");
      } else {
        strictBoolean("busy");
        fields.optionalText("title");
        blockedReason();
      }
    } else {
      for (const auto name : {"hook_event_name", "tool_use_id"}) {
        fields.text(name);
      }

      if (provider == AgentProvider::cursor) {
        for (const auto name : {"conversation_id", "tool_output", "chat_meta"}) {
          fields.text(name);
        }
        if (const auto roots = fields.value("workspace_roots")) {
          roots->eachElement([&](JsonValue root) {
            String<Memory> decoded{AllocatorRef<char, Memory>{memory}};
            root.string(decoded);
            if (!workspace_) {
              workspace_ = std::move(decoded);
            }
          });
        }
      } else {
        fields.optionalText("agent_id");
        for (const auto name : {"session_id", "transcript_path"}) {
          fields.text(name);
        }

        if (provider == AgentProvider::claude) {
          for (const auto name : {"session_title", "notification_type", "message", "last_assistant_message", "new_cwd"}) {
            fields.text(name);
          }
          if (const auto tasks = fields.value("background_tasks")) {
            tasks->eachElement([&](JsonValue value) {
              Object task{memory, value, true};
              const auto type = task.text("type");
              const auto status = task.text("status");
              running_subagents += type == "subagent" && status == "running";
            });
          }
        } else {
          fields.text("source");
          fields.text("state_database");
          fields.optionalText("last_assistant_message");
          fields.template integer<std::size_t>("running_subagents");
        }
      }
    }
  }

  inline std::string_view event() { return fields.text(provider == AgentProvider::pi || provider == AgentProvider::opencode ? "event" : "hook_event_name"); }
  inline std::string_view session() { return fields.text(provider == AgentProvider::cursor ? "conversation_id" : "session_id"); }
  inline bool subagent() { return !fields.optionalText("agent_id").value_or("").empty(); }
  inline std::string_view workspace() const noexcept { return workspace_ ? std::string_view{*workspace_} : std::string_view{}; }

  inline std::string_view toolEvent() {
    const auto name = event();
    if (provider != AgentProvider::cursor) {
      return name;
    }
    if (name == "preToolUse") {
      return "PreToolUse";
    }
    if (name == "postToolUse" || name == "postToolUseFailure") {
      return "PostToolUse";
    }

    return name;
  }

  inline AgentBlockedReason blockedReason() {
    const auto name = fields.value("blocked") ? fields.text("blocked") : "none";
    constexpr std::array names{"none", "permission", "question", "plan", "other"};
    const auto found = std::ranges::find(names, name);
    if (found == names.end()) {
      throw std::invalid_argument{"Unknown hook blocked reason"};
    }

    return static_cast<AgentBlockedReason>(found - names.begin());
  }

  Memory &memory;
  AgentProvider provider;
  Object<Memory> fields;
  Object<Memory> tools;
  std::size_t running_subagents = 0;

private:
  inline void strictBoolean(std::string_view name) {
    if (fields.value(name) && !fields.boolean(name).has_value()) {
      throw std::invalid_argument{"Expected hook boolean"};
    }
  }

  inline static JsonValue toolObject(const Object<Memory> &fields) {
    const auto value = fields.value("tool_input");
    return value && value->encoded().starts_with('{') ? *value : JsonValue{"{}"};
  }

  std::optional<String<Memory>> workspace_;
};

template <Allocator Memory>
Payload(Memory &memory, AgentProvider provider, JsonValue input) -> Payload<Memory>;

template <Allocator Memory>
Payload(Memory &memory, AgentProvider provider, Object<Memory> input) -> Payload<Memory>;

}
}

// Interface: hooks/text.cppm
export {
namespace telar::runtime::cli::hooks {

inline std::string_view sessionReference(std::string_view text) noexcept {
  if (text.empty() || text.size() > 64 || text.front() == '-') {
    return {};
  }

  for (const unsigned char byte : text) {
    const bool allowed = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-' || byte == ':';
    if (!allowed) {
      return {};
    }
  }

  return text;
}

inline std::string_view validPrefix(std::string_view text) noexcept {
  while (!text.empty()) {
    try {
      validateUtf8(text);
      return text;
    } catch (const EncodingError &) {
      text.remove_suffix(1);
    }
  }

  return {};
}

inline void eventLine(FixedText<96> &output, std::string_view text) {
  const auto control = std::ranges::find_if(text, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; });
  const auto prefix = utf8Prefix(text.substr(0, static_cast<std::size_t>(control - text.begin())), 96);
  try {
    validateUtf8(prefix);
    output.assign(prefix);
  } catch (const EncodingError &) {
    output.assign({});
  }
}

template <std::size_t Capacity>
void displayText(FixedText<Capacity> &output, std::string_view text, bool multiline) {
  std::array<char, Capacity> bytes;
  std::size_t length = 0;
  for (const unsigned char byte : text) {
    if (length == bytes.size() || (!multiline && byte == '\n')) {
      break;
    }
    if ((byte >= 0x20 && byte != 0x7f) || (multiline && (byte == '\n' || byte == '\t'))) {
      bytes[length++] = static_cast<char>(byte);
    }
  }

  std::string_view result{bytes.data(), length};
  if (multiline) {
    const auto first = result.find_first_not_of(" \n\t");
    result = first == std::string_view::npos ? std::string_view{} : result.substr(first, result.find_last_not_of(" \n\t") - first + 1);
  }

  output.assign(validPrefix(result));
}

inline bool defaultOpenCodeTitle(std::string_view title) noexcept {
  constexpr std::string_view shape = "0000-00-00T00:00:00.000Z";
  for (const auto prefix : {std::string_view{"New session - "}, std::string_view{"Child session - "}}) {
    if (!title.starts_with(prefix) || title.size() != prefix.size() + shape.size()) {
      continue;
    }

    title.remove_prefix(prefix.size());
    for (std::size_t index = 0; index < shape.size(); ++index) {
      if (shape[index] == '0' ? title[index] < '0' || title[index] > '9' : title[index] != shape[index]) {
        return false;
      }
    }

    return true;
  }

  return false;
}

}
}

// Interface: hooks/command.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
std::optional<std::int32_t> commandExitCode(Payload<Memory> &input) {
  if (input.provider == AgentProvider::claude) {
    return input.event() == "PostToolUse" ? std::optional<std::int32_t>{0} : std::nullopt;
  }
  if (input.provider == AgentProvider::codex) {
    return std::nullopt;
  }
  if (input.provider != AgentProvider::cursor) {
    return input.fields.template integer<std::int32_t>("exit_code");
  }
  if (input.event() != "postToolUse" || input.fields.text("tool_name") != "Shell") {
    return std::nullopt;
  }

  try {
    Object output{input.memory, JsonValue::parse(input.fields.text("tool_output")), true};
    return output.template integer<std::int32_t>("exitCode");
  } catch (const std::exception &) {
    return std::nullopt;
  }
}

template <Allocator Memory>
std::optional<ReportAgentCommand> commandReport(Payload<Memory> &input) {
  if ((input.provider == AgentProvider::claude || input.provider == AgentProvider::codex) && input.subagent()) {
    return std::nullopt;
  }

  const auto event = input.toolEvent();
  const bool started = event == "PreToolUse" || event == "tool_execution_start" || event == "tool.execute.before";
  const bool finished = event == "PostToolUse" || event == "tool_execution_end" || event == "tool.execute.after";
  if (!started && !finished) {
    return std::nullopt;
  }

  const auto provider = describeProvider(input.provider).name;
  const auto *manifest = builtin_manifests.find(input.provider);
  const auto field = manifest == nullptr ? std::string_view{} : manifest->commandField(input.fields.text("tool_name"));
  const auto command = input.tools.stringField(field);
  if (!command || command->empty()) {
    return std::nullopt;
  }

  const auto cwd = input.fields.text("cwd");
  return ReportAgentCommand{
      .phase = started ? AgentCommandPhase::started : AgentCommandPhase::finished,
      .provider = provider,
      .tool_call_id = input.fields.text(input.provider == AgentProvider::pi || input.provider == AgentProvider::opencode ? "tool_call_id" : "tool_use_id"),
      .command = *command,
      .cwd = input.provider == AgentProvider::cursor && cwd.empty() ? input.workspace() : cwd,
      .session = sessionReference(input.session()),
      .exit_code = started ? std::nullopt : commandExitCode(input),
  };
}

}
}

// Interface: hooks/event.cppm
export {
namespace telar::runtime::cli::hooks {

template <Allocator Memory>
void toolEvent(FixedText<96> &output, Payload<Memory> &input) {
  const auto name = input.fields.text("tool_name");
  if (name.empty()) {
    output.assign({});
    return;
  }

  std::array<char, 192> buffer;
  std::size_t length = 0;
  const auto append = [&](std::string_view text) {
    const auto count = std::min(text.size(), buffer.size() - length);
    std::memcpy(buffer.data() + length, text.data(), count);
    length += count;
  };
  append("» ");
  append(name);
  for (const auto key : {"command", "cmd", "file_path", "filePath", "filepath", "path", "pattern", "url", "query", "prompt", "description"}) {
    if (const auto argument = input.tools.stringField(key); argument && !argument->empty()) {
      append(" ");
      append(*argument);
      break;
    }
  }

  eventLine(output, {buffer.data(), length});
}

template <Allocator Memory>
bool questionEvent(FixedText<96> &output, Payload<Memory> &input) {
  const auto questions = input.tools.value("questions");
  if (!questions || !questions->encoded().starts_with('[')) {
    return false;
  }

  bool first = true;
  bool found = false;
  questions->eachElement([&](JsonValue value) {
    if (!std::exchange(first, false) || !value.encoded().starts_with('{')) {
      return;
    }

    Object question{input.memory, value};
    if (const auto text = question.stringField("question"); text && !text->empty()) {
      eventLine(output, *text);
      found = true;
    }
  });

  return found;
}

inline void backgroundEvent(FixedText<96> &output, std::size_t count) {
  std::array<char, 96> buffer;
  const auto length = std::snprintf(buffer.data(), buffer.size(), "waiting for %zu background %s", count, count == 1 ? "agent" : "agents");
  output.assign({buffer.data(), static_cast<std::size_t>(length)});
}

}
}
