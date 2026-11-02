#pragma once

#include "presentation/history_actions.hpp"
#include "text/bounded_text.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

enum class HistoryFooterAction : std::uint8_t {
  none,
  submit,
  alternate,
  inspect,
  visit,
};

struct HistoryFooterHint {
  std::string_view key;
  std::string_view word;
  HistoryFooterAction action = HistoryFooterAction::none;
};

struct HistoryFooterOptions {
  HistoryKeyStyle key_style = HistoryKeyStyle::pc;
  std::uint32_t offset = 0;
  std::uint16_t count = 0;
  bool inspecting = false;
  bool enter_runs = false;
  bool has_more = false;
  bool fuzzy = false;
  bool has_query = false;
};

struct HistoryFooter {
  static constexpr std::size_t browse_count = 3;
  static constexpr std::size_t inspect_count = 4;
  static constexpr std::size_t capacity = inspect_count;
  static constexpr std::size_t range_capacity = 64;
  using Range = BoundedText<range_capacity>;

  std::array<HistoryFooterHint, capacity> hints{};
  std::size_t count = 0;

  [[nodiscard]] static constexpr HistoryFooter resolve(HistoryFooterOptions options) noexcept {
    const bool mac = options.key_style == HistoryKeyStyle::mac;
    HistoryFooter result;
    result.hints.front() = {.key = mac ? "↩" : "Enter", .word = options.enter_runs ? "run" : "paste", .action = HistoryFooterAction::submit};
    if (options.inspecting) {
      result.hints[1] = {.key = HistoryActions::inspectionKey(options.key_style), .word = "back", .action = HistoryFooterAction::inspect};
      result.hints[2] = {.key = mac ? "⇞⇟" : "PgUp PgDn", .word = "scroll"};
      result.hints[3] = {.key = mac ? "⌥↩" : "Alt+Enter", .word = "go to pane", .action = HistoryFooterAction::visit};
      result.count = inspect_count;
    } else {
      result.hints[1] = {.key = mac ? "⇧↩" : "Shift+Enter", .word = options.enter_runs ? "paste" : "run", .action = HistoryFooterAction::alternate};
      result.hints[2] = {.key = HistoryActions::inspectionKey(options.key_style), .word = "details", .action = HistoryFooterAction::inspect};
      result.count = browse_count;
    }

    return result;
  }

  [[nodiscard]] static Range range(HistoryFooterOptions options) {
    Range result;
    result.appendDecimal(static_cast<std::uint64_t>(options.offset) + 1);
    result.append("–");
    result.appendDecimal(static_cast<std::uint64_t>(options.offset) + options.count);
    if (options.has_more) {
      result.append(options.key_style == HistoryKeyStyle::mac ? "  ·  ⇞ older" : "  ·  PgUp older");
    }

    if (options.fuzzy && options.has_query) {
      result.append("  ·  fuzzy");
    }

    return result;
  }
};

}
