module;
#include "tbc/annotations.hpp"

export module telar.gui.graphics.placeholder;

import std;

import telar.gui.foundation.core;

import telar.gui.foundation.terminal;
import telar.wire.vocabulary;

// Interface: graphics/source_rect.cppm
export {
  namespace telar::gui {

    struct ImageSourceRect {
      std::uint32_t x = 0;
      std::uint32_t y = 0;
      std::uint32_t width = 0;
      std::uint32_t height = 0;

      [[nodiscard]] static ImageSourceRect resolve(const GraphicsPlacement& placement, const ImageDescription& image) noexcept;
      [[nodiscard]] Rect pixels() const noexcept;
    };

  }
}

// Interface: graphics/display_box.cppm
export {
  namespace telar::gui {

    struct ImageDisplayBox {
      struct Cell {
        std::uint32_t width = 0;
        std::uint32_t height = 0;

        bool operator==(const Cell&) const noexcept = default;
      };

      std::int64_t x = 0;
      std::int64_t y = 0;
      std::uint32_t width = 0;
      std::uint32_t height = 0;

      [[nodiscard]] static ImageDisplayBox resolve(const GraphicsPlacement& placement, ImageSourceRect source, Cell cell) noexcept;

    private:
      [[nodiscard]] static std::uint32_t filledExtent(std::uint32_t cell, std::uint32_t count) noexcept;
      [[nodiscard]] static std::uint32_t proportionalExtent(std::uint32_t value, std::uint32_t numerator, std::uint32_t denominator) noexcept;
    };

  }
}

// Interface: graphics/placement.cppm
export {
  namespace telar::gui {

    struct ImageGeometry {
      Rect source;
      Rect destination;

      [[nodiscard]] ImageGeometry clipped(Rect bounds) const noexcept;
      [[nodiscard]] static Rect textureSource(Rect source, Rect texture) noexcept;
      [[nodiscard]] static Rect remapSource(Rect fragment, Rect original, Rect substitute) noexcept;
      static ImageGeometry resolve(const GraphicsPlacement& placement, const ImageDescription& image, Point cell, float scale) noexcept;
      [[nodiscard]] static ImageDisplayBox::Cell physicalCell(Point logical, float scale) noexcept;

    private:
      [[nodiscard]] static std::uint32_t physicalExtent(float logical, float scale) noexcept;
    };

    bool placementOrder(const GraphicsPlacement& left, const GraphicsPlacement& right) noexcept;

  }
}

// Interface: graphics/placeholder.cppm
export {
  namespace telar::gui {

    struct PlaceholderCell {
      std::uint32_t image_low = 0;
      std::uint32_t placement = 0;
      std::optional<std::uint32_t> row;
      std::optional<std::uint32_t> column;
      std::optional<std::uint32_t> image_high;
    };

    std::optional<std::uint32_t> placeholderMark(std::string_view& text) noexcept;
    std::uint32_t placeholderColor(const CellColor& color) noexcept;
    std::optional<PlaceholderCell> parsePlaceholder(const CellValue& cell) noexcept;

    struct PlaceholderRun {
      std::uint32_t screen_column = 0;
      std::uint32_t image_id = 0;
      std::uint32_t placement_id = 0;
      std::uint32_t row = 0;
      std::uint32_t column = 0;
      std::uint32_t width = 1;
      std::uint32_t image_low = 0;
      std::optional<std::uint32_t> image_high;

      static PlaceholderRun begin(const PlaceholderCell& cell, std::uint32_t screen_column) noexcept;
      bool extend(const PlaceholderCell& cell) noexcept;
    };

    ImageGeometry placeholderGeometry(const PlaceholderRun& run, const GraphicsPlacement& placement, ImageGeometry base, Point cell, float scale) noexcept;
    ImageGeometry placeholderGeometry(const PlaceholderRun& run, const GraphicsPlacement& placement, const ImageDescription& image, Point cell, float scale) noexcept;

  }
}
