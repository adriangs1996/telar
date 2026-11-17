export module telar.gui.foundation.forms:form_field_geometry;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;

// Interface: presentation/form_field_geometry.cppm
export {
  namespace telar::gui::inline foundation::inline forms {

    struct FormFieldGeometry {
      static constexpr float horizontal_padding = 12;
      static constexpr float vertical_padding = 8;
      static constexpr float caret_width = 1;
      static constexpr float underline_offset = 2;
      static constexpr float underline_height = 1;

      Rect content;
      float cell_width = 1;
      float line_height = 1;
      float insertion_width = 1;
      std::uint16_t columns = 0;

      [[nodiscard]] static FormFieldGeometry derive(Rect bounds, ChromeMetrics chrome, const FontGrid& grid) noexcept;
      [[nodiscard]] Rect caret(std::uint16_t column) const noexcept;
      [[nodiscard]] static FormFieldGeometry terminal(Rect bounds, const FontGrid& grid) noexcept;
      [[nodiscard]] Rect selection(EditorColumns selected) const noexcept;
      [[nodiscard]] Rect underline(std::uint32_t text_columns) const noexcept;
    };

  }
}
