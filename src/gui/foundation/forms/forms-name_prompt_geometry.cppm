export module telar.gui.foundation.forms:name_prompt_geometry;

import std;

import telar.gui.foundation.core;

// Interface: presentation/name_prompt_geometry.cppm
export {
  namespace telar::gui::inline foundation::inline forms {

    struct NamePromptGeometry {
      static constexpr std::uint16_t requested_width = 64;
      static constexpr std::uint16_t requested_height = 7;
      static constexpr std::uint16_t horizontal_threshold = 12;
      static constexpr std::uint16_t vertical_threshold = 6;
      static constexpr std::uint16_t horizontal_margin = 2;
      static constexpr std::uint16_t vertical_margin = 1;

      CellRectangle bounds;
      CellRectangle title;
      CellRectangle field;
      CellRectangle footer;

      [[nodiscard]] static NamePromptGeometry measure(CellRectangle host, CellRectangle wanted = {.width = requested_width, .height = requested_height}) noexcept;

    private:
      [[nodiscard]] static std::uint16_t coordinate(std::uint32_t value) noexcept;
    };

  }
}
