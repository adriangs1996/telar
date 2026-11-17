export module telar.gui.foundation.terminal:font_grid;

import std;

import telar.gui.foundation.core;

// Interface: terminal/font_grid.cppm
export {
  namespace telar::gui::inline foundation::inline terminal {

    struct FontMetrics {
      std::int32_t ascender = 0;
      std::uint32_t line_height = 1;
      std::uint16_t maximum_advance = 1;
      float box_stroke = 1;

      [[nodiscard]] static std::int32_t roundFixed(std::int64_t value);
    };

    struct FontGrid {
      std::uint16_t width = 1;
      std::uint16_t height = 1;
      std::uint16_t pixel_height = 1;
      float baseline = 0;
      float box_stroke = 1;

      [[nodiscard]] static std::uint16_t pixelHeight(const FontConfiguration& font, float scale);
      [[nodiscard]] static FontGrid resolve(const FontMetrics& metrics, const FontConfiguration& font, float scale);
    };

  }
}

// Interface: terminal/glyphs/alpha_raster.cppm
export {
  namespace telar::gui::inline foundation::inline terminal {

    struct AlphaRaster {
      std::span<std::uint8_t> pixels;
      std::size_t stride = 0;
      std::uint16_t width = 0;
      std::uint16_t height = 0;

      [[nodiscard]] bool empty() const noexcept;
      void validate() const;
    };

  }
}
