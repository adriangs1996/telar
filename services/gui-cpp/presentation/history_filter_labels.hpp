#pragma once

#include "history_actions.hpp"
#include <array>
#include <cstddef>
#include <string_view>

namespace telar::gui {

struct HistoryFilterLabels {
  struct Choice {
    std::string_view value;
    std::string_view text;
  };

  static constexpr std::array scopes{
      Choice{.value = "global", .text = "All"},
      Choice{.value = "workspace", .text = "Workspace"},
      Choice{.value = "cwd", .text = "Directory"},
      Choice{.value = "pane", .text = "Pane"},
  };
  static constexpr std::array authors{
      Choice{.value = "human", .text = "You"},
      Choice{.value = "agent", .text = "Agents"},
      Choice{.value = "all", .text = "Both"},
  };
  static constexpr std::size_t key_count = 3;
  static constexpr std::string_view failed = "Failed";

  [[nodiscard]] static constexpr std::array<std::string_view, key_count> keys(HistoryKeyStyle style) noexcept {
    return style == HistoryKeyStyle::mac ? std::array<std::string_view, key_count>{"⇥", "⇧⇥", "!"} : std::array<std::string_view, key_count>{"Tab", "Shift+Tab", "!"};
  }
};

}
