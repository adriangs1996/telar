#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

enum class HistoryKeyStyle : std::uint8_t {
  mac,
  pc,
};

enum class HistoryCardAction : std::uint8_t {
  copy,
  erase,
  visit,
};

enum class HistoryInspectionAction : std::uint8_t {
  submit,
  alternate,
  copy,
  erase,
  visit,
};

inline constexpr std::size_t history_inspection_action_count = 5;

struct HistoryActionLabel {
  std::string_view key;
  std::string_view word;
  HistoryCardAction action;
};

struct HistoryActions {
  static constexpr std::size_t count = 3;

  [[nodiscard]] static constexpr std::array<HistoryActionLabel, count> labels(HistoryKeyStyle style) noexcept {
    if (style == HistoryKeyStyle::mac) {
      return {
          HistoryActionLabel{.key = "⌘C", .word = "copy", .action = HistoryCardAction::copy},
          HistoryActionLabel{.key = "⌘⌫", .word = "delete", .action = HistoryCardAction::erase},
          HistoryActionLabel{.key = "⌥↩", .word = "go to pane", .action = HistoryCardAction::visit},
      };
    }

    return {
        HistoryActionLabel{.key = "Ctrl+C", .word = "copy", .action = HistoryCardAction::copy},
        HistoryActionLabel{.key = "Ctrl+D", .word = "delete", .action = HistoryCardAction::erase},
        HistoryActionLabel{.key = "Alt+Enter", .word = "go to pane", .action = HistoryCardAction::visit},
    };
  }

  [[nodiscard]] static constexpr std::string_view inspectionKey(HistoryKeyStyle style) noexcept {
    return style == HistoryKeyStyle::mac ? "⌃O" : "Ctrl+O";
  }
};

}
