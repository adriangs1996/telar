module;
#include "tbc/annotations.hpp"

export module telar.gui.palette.navigation_label;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.text;

// Interface: palette/navigation_label.cppm
export {
  namespace telar::gui {

    class NavigationLabel {
    public:
      static constexpr std::size_t capacity = 160;
      static constexpr std::string_view detail_separator = "  ";
      static constexpr std::string_view tab_prefix = "tab ";

      void append(std::string_view text);
      void appendDetail(std::string_view detail);
      [[nodiscard]] std::string_view view() const noexcept;

    private:
      BoundedText<capacity> text_;
    };

  }
}

// Interface: palette/navigation_target.cppm
export {
  namespace telar::gui {

    struct AgentNavigationTarget {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;

      bool operator==(const AgentNavigationTarget&) const = default;
    };

    using NavigationTarget = std::variant<WorkspaceLocation, TabLocation, AgentNavigationTarget>;

  }
}

// Interface: palette/query.cppm
export {
  namespace telar::gui {

    enum class PaletteMode : std::uint8_t {
      actions = '>',
      navigate = '@',
      suggest = '?',
      machines = ':',
    };

    struct PaletteQuery {
      static constexpr std::size_t maximum_bytes = 512;

      PaletteMode mode = PaletteMode::navigate;
      std::string_view text;

      [[nodiscard]] static constexpr std::optional<PaletteMode> prefix(char byte) noexcept {
        switch (byte) {
        case static_cast<char>(PaletteMode::actions):
          return PaletteMode::actions;
        case static_cast<char>(PaletteMode::navigate):
          return PaletteMode::navigate;
        case static_cast<char>(PaletteMode::suggest):
          return PaletteMode::suggest;
        case static_cast<char>(PaletteMode::machines):
          return PaletteMode::machines;
        default:
          return std::nullopt;
        }
      }

      [[nodiscard]] static constexpr PaletteQuery parse(std::string_view prompt) noexcept {
        if (!prompt.empty()) {
          if (const auto mode = prefix(prompt.front())) {
            prompt.remove_prefix(1);

            return {.mode = *mode, .text = prompt};
          }
        }

        return {.text = prompt};
      }
    };

  }
}
