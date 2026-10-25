#pragma once

#include "../../agents/provider.hpp"
#include "object.hpp"
#include "validation.hpp"

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
class Payload {
public:
  explicit Payload(Memory &memory, AgentProvider provider, JsonValue input)
      : Payload(memory, provider, Object<Memory>{memory, input, true}) {}

  explicit Payload(Memory &memory, AgentProvider provider, Object<Memory> input)
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

  std::string_view event() { return fields.text(provider == AgentProvider::pi || provider == AgentProvider::opencode ? "event" : "hook_event_name"); }
  std::string_view session() { return fields.text(provider == AgentProvider::cursor ? "conversation_id" : "session_id"); }
  bool subagent() { return !fields.optionalText("agent_id").value_or("").empty(); }
  std::string_view workspace() const noexcept { return workspace_ ? std::string_view{*workspace_} : std::string_view{}; }

  std::string_view toolEvent() {
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

  AgentBlockedReason blockedReason() {
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
  void strictBoolean(std::string_view name) {
    if (fields.value(name) && !fields.boolean(name).has_value()) {
      throw std::invalid_argument{"Expected hook boolean"};
    }
  }

  static JsonValue toolObject(const Object<Memory> &fields) {
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
