export module telar.gui.ui.design.controls:form_text_grid;

import std;
import telar.gui.qt;
import :cell_text_grid;
import telar.gui.ui.kit.fonts;
import telar.gui.foundation.fonts;

export namespace telar::gui::qt {

  struct FormTextGrid {
    [[tbc::hot_path]] [[nodiscard]] inline static CellTextGrid resolve(const QString& family, const QString& style, std::uint16_t pixels) {
      const auto source = ResidentFonts::resolveSource(family, style);
      const auto resident = ResidentFonts::shared(source);
      const auto metrics = resident->face(fonts::FontRole::primary).metrics(pixels);

      return {
          .metrics = {.width = metrics.maximum_advance, .height = static_cast<std::uint16_t>(std::min(metrics.line_height, static_cast<std::uint32_t>(std::numeric_limits<std::uint16_t>::max()))), .pixel_height = pixels, .baseline = static_cast<float>(metrics.ascender)},
          .family = family,
          .style = style,
      };
    }
  };

}
