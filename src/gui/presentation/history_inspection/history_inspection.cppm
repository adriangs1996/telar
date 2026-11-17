module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.history_inspection;

import std;

import telar.gui.foundation.core;

// Interface: presentation/workspace_mark.cppm
export {
  namespace telar::gui {

    struct WorkspaceMark {
      static constexpr auto hues = std::to_array<PaletteRole>({PaletteRole::red, PaletteRole::peach, PaletteRole::yellow, PaletteRole::green, PaletteRole::teal, PaletteRole::blue, PaletteRole::mauve});

      Utf8Scalar initial;
      PaletteRole hue = hues.front();

      [[nodiscard]] static WorkspaceMark resolve(std::string_view name);

    private:
      [[nodiscard]] static std::uint32_t hash(std::string_view name) noexcept;
    };

  }
}
