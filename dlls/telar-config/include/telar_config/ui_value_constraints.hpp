#pragma once

#include "telar_base/text/ascii.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_config/limit_notices.hpp"
#include "telar_config/value_constraints.hpp"

namespace telar::runtime::config {

inline void printableUiText(const lua::Value &source, std::string_view text, bool allow_tab = false) {
  validateUtf8(text);
  if (std::ranges::any_of(text, [allow_tab](unsigned char byte) { return (byte < 0x20 && !(allow_tab && byte == '\t')) || byte == 0x7f; })) {
    source.fail("must contain printable text");
  }
}

inline std::string_view fittedUiText(std::string_view text, LimitReach reach, LimitNotices &limits) {
  if (text.size() > reach.value) {
    reach.requested = text.size();
    limits.add(reach);
  }
  return utf8Prefix(text, reach.value);
}

inline bool equalUiName(std::string_view left, std::string_view right) noexcept {
  return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(), [](char byte, char expected) { return (byte == '-' ? '_' : asciiLower(byte)) == expected; });
}

inline void uiIcon(const lua::Value &value) {
  constexpr std::string_view names[]{"sidebar_collapse", "sidebar_expand", "workspace_menu", "proxy_active", "cpu", "memory", "battery_empty", "battery_quarter", "battery_half", "battery_three_quarters", "battery_full", "provider_unknown", "provider_claude", "provider_codex", "provider_pi", "provider_cursor", "provider_opencode", "app_terminal", "app_editor", "app_git", "agent_unknown", "agent_working_0", "agent_working_1", "agent_working_2", "agent_working_3", "agent_blocked", "agent_ready", "agent_done", "agent_failed", "close", "pane_fullscreen", "telar_mark"};
  const auto text = value.string();
  if (!std::ranges::any_of(names, [text](std::string_view name) { return equalUiName(text, name); })) {
    value.fail("names an unknown icon");
  }
}

inline void uiMark(const lua::Value &value) {
  value.string();
  optionalChoice(value, {"claude", "codex", "pi", "telar"});
}

inline void hexadecimalColor(const lua::Value &value) {
  const auto text = value.string();
  if (text.size() != 7 || text.front() != '#' || !std::ranges::all_of(text.substr(1), [](char byte) { return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f'); })) {
    value.fail("must be an RGB hexadecimal color");
  }
}

}
