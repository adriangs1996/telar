#pragma once

#include "telar_config/action_validator.hpp"
#include "telar_plugins/action_protocol.hpp"
#include <bit>

namespace telar::runtime::plugins {

class ActionEncoder {
public:
  explicit ActionEncoder(const config::RetainedActionValidator &validator)
      : validator_(validator) {}

  std::span<const Byte> encode(const lua::Value &result) {
    auto output = std::span{storage_}.subspan(1);
    Byte count = 0;
    if (result.field("kind").present()) {
      count = static_cast<Byte>(append(result, output));
    } else {
      const auto length = std::min(result.listLength(), ActionProtocol::maximum_effects);
      for (std::size_t index = 0; index < length; ++index) {
        count += static_cast<Byte>(append(result.element(static_cast<lua_Integer>(index) + 1), output));
      }
    }

    storage_[0] = count;
    return std::span{storage_}.first(storage_.size() - output.size());
  }

private:
  bool append(const lua::Value &value, std::span<Byte> &output) const {
    if (value.is(LUA_TFUNCTION)) {
      value.fail("cannot return another callback");
    }

    if (!validator_.validate(value)) {
      return false;
    }

    if (value.is(LUA_TSTRING)) {
      builtin(value.string(), output);
    } else {
      const auto kind = value.field("kind");
      const auto name = kind.string();
      if (name == "notification") {
        notification(value, output);
      } else if (name == "select-tab" || name == "select-workspace") {
        tag(name == "select-tab" ? ActionTag::select_tab : ActionTag::select_workspace, output);
        u8::encode(static_cast<Byte>(value.field("index").integer() - 1), output);
      } else if (name == "select-tab-offset") {
        tag(ActionTag::tab_offset, output);
        u8::encode(static_cast<Byte>(value.field("offset").integer()), output);
      } else if (name == "split-pane" || name == "focus-pane" || name == "resize-pane" || name == "resize-sidebar" || name == "move-tab") {
        directional(name, value.field("direction").string(), output);
      } else {
        builtin(name, output);
      }
    }

    return true;
  }

  static void tag(ActionTag value, std::span<Byte> &output) {
    u8::encode(static_cast<Byte>(value), output);
  }

  static void directional(std::string_view name, std::string_view direction, std::span<Byte> &output) {
    constexpr auto kinds = std::to_array<std::pair<std::string_view, ActionTag>>({
        {"split-pane", ActionTag::split},
        {"focus-pane", ActionTag::focus},
        {"resize-pane", ActionTag::resize},
        {"resize-sidebar", ActionTag::resize_sidebar},
        {"move-tab", ActionTag::move_tab},
    });
    const auto *found = std::ranges::find(kinds, name, &decltype(kinds)::value_type::first);
    if (found == kinds.end()) {
      throw lua::Error{"Unsupported directional plugin effect"};
    }

    const auto kind = found->second;
    constexpr std::array directions{"left", "right", "up", "down"};
    Byte index = 0;
    if (kind == ActionTag::split) {
      index = static_cast<Byte>(direction == "vertical");
    } else if (kind == ActionTag::move_tab) {
      index = static_cast<Byte>(direction == "next");
    } else {
      index = static_cast<Byte>(std::ranges::find(directions, direction) - directions.begin());
    }

    tag(kind, output);
    u8::encode(index, output);
  }

  static void builtin(std::string_view name, std::span<Byte> &output) {
    constexpr auto simple = std::to_array<std::pair<std::string_view, ActionTag>>({
        {"toggle-sidebar", ActionTag::sidebar},
        {"close-pane", ActionTag::close_pane},
        {"new-tab", ActionTag::new_tab},
        {"rename-tab", ActionTag::rename_tab},
        {"close-tab", ActionTag::close_tab},
        {"detach", ActionTag::detach},
        {"toggle-pane-fullscreen", ActionTag::fullscreen},
        {"toggle-workspace-list", ActionTag::workspace_list},
        {"new-workspace", ActionTag::new_workspace},
        {"rename-workspace", ActionTag::rename_workspace},
        {"leave-worktree", ActionTag::leave_worktree},
    });
    for (const auto &[known, value] : simple) {
      if (name == known) {
        tag(value, output);
        return;
      }
    }

    if (name == "next-tab" || name == "previous-tab") {
      tag(ActionTag::tab_offset, output);
      u8::encode(name == "next-tab" ? Byte{1} : std::bit_cast<Byte>(std::int8_t{-1}), output);
      return;
    }

    constexpr auto stems = std::to_array<std::pair<std::string_view, std::string_view>>({
        {"resize-sidebar-", "resize-sidebar"},
        {"move-tab-", "move-tab"},
        {"split-", "split-pane"},
        {"focus-", "focus-pane"},
        {"resize-", "resize-pane"},
    });
    for (const auto &[prefix, kind] : stems) {
      if (name.starts_with(prefix)) {
        directional(kind, name.substr(prefix.size()), output);
        return;
      }
    }

    for (const auto &[prefix, kind] : {std::pair{std::string_view{"select-tab-"}, ActionTag::select_tab}, std::pair{std::string_view{"select-workspace-"}, ActionTag::select_workspace}}) {
      if (name.starts_with(prefix)) {
        unsigned index = 0;
        constexpr unsigned radix = 10;
        for (const char byte : name.substr(prefix.size())) {
          if (byte != '_') {
            index = (index * radix) + static_cast<unsigned>(byte - '0');
          }
        }

        tag(kind, output);
        u8::encode(static_cast<Byte>(index - 1), output);
        return;
      }
    }

    throw lua::Error{"Action is not supported by the plugin worker protocol"};
  }

  static void text(std::string_view value, std::span<Byte> &output) {
    u16::encode(static_cast<std::uint16_t>(value.size()), output);
    if (value.size() > output.size()) {
      throw EncodingError{"Plugin result exceeds its bounds"};
    }

    std::ranges::copy(value, output.begin());
    output = output.subspan(value.size());
  }

  static void notification(const lua::Value &value, std::span<Byte> &output) {
    tag(ActionTag::notification, output);
    const auto level = value.field("level");
    constexpr std::array levels{"info", "success", "warning", "failure"};
    u8::encode(level.present() ? static_cast<Byte>(std::ranges::find(levels, level.string()) - levels.begin()) : Byte{0}, output);
    u32::encode(static_cast<std::uint32_t>(value.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms)), output);
    constexpr std::array targets{"pane_id", "tab_id", "workspace_id"};
    Byte target_kind = 0;
    std::uint64_t target_id = 0;
    for (std::size_t index = 0; index < targets.size(); ++index) {
      const auto target = value.field(targets[index]);
      if (target.present()) {
        target_kind = static_cast<Byte>(index + 1);
        target_id = static_cast<std::uint64_t>(target.integer());
      }
    }

    u8::encode(target_kind, output);
    if (target_kind != 0) {
      u64::encode(target_id, output);
    }

    text(utf8Prefix(value.field("title").string(), max_notification_title_bytes), output);
    const auto body = value.field("body");
    text(body.present() ? utf8Prefix(body.string(), max_notification_message_bytes) : std::string_view{}, output);
  }

  const config::RetainedActionValidator &validator_;
  std::array<Byte, ActionProtocol::maximum_bytes> storage_;
};

}
