module;
#include "tbc/annotations.hpp"

export module telar.gui.graphics.placeholder;

import std;

import telar.gui.core.metrics;

import telar.gui.terminal.screen;
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

// Interface: graphics/rounded_rectangle.cppm
export {
  namespace telar::gui {

    struct RoundedRectangleStyle {
      Color fill{.a = 0};
      Color border{.a = 0};
      float radius = 0;
      float border_width = 0;
      Color backdrop{.a = 0};
      bool replace_background = false;

      bool operator==(const RoundedRectangleStyle&) const = default;
    };

    struct RoundedRectangle {
      Point size;
      RoundedRectangleStyle style;

      [[nodiscard]] static RoundedRectangle resolve(Point size, RoundedRectangleStyle style) noexcept;
      [[nodiscard]] Color sample(Point local) const noexcept;

      bool operator==(const RoundedRectangle&) const = default;
    };

    struct RoundedRectanglePaint {
      Point origin{};
      RoundedRectangle shape;

      [[nodiscard]] RoundedRectanglePaint clipped(Rect clip) const noexcept;
    };

  }
}

namespace telar::gui {

  // A caller's paint visitor behind a function pointer, so that the shapes are computed in placeholder.cpp.
  struct PaintSink {
    void* context;
    void (*call)(void* context, const RoundedRectanglePaint& paint);

    // Generic over the caller's visitor, so it stays here.
    template <typename Visitor>
    TBC_GENERIC static PaintSink of(Visitor& visitor) noexcept {
      return {
          .context = &visitor,
          .call = [](void* context, const RoundedRectanglePaint& paint) {
            (*static_cast<Visitor*>(context))(paint);
          },
      };
    }

    void operator()(const RoundedRectanglePaint& paint) const;
  };

}

// Interface: graphics/progress_ring.cppm
export {
  namespace telar::gui {

    struct ProgressRing {
      static constexpr std::size_t segments = 64;
      static constexpr std::size_t maximum_paints = segments + 2;
      static constexpr float stroke_ratio = 0.12F;
      static constexpr float track_alpha = 0.18F;
      Rect area;
      Color color;
      float fraction = 0;
      float rotation = 0;
      // Zero derives the stroke from the side.
      float stroke_width = 0;
      // Without a track colour the track is the ring's colour at track_alpha; a transparent one draws no track.
      std::optional<Color> track = std::nullopt;

      template <typename Visitor>
      TBC_GENERIC void visit(Visitor visitor) const {
        visit(PaintSink::of(visitor));
      }

      void visit(PaintSink visitor) const;

    private:
      [[nodiscard]] static Point endpoint(float fraction) noexcept;

      static const std::array<Point, segments> circle;
    };

  }
}

// Interface: graphics/progress_capsule.cppm
export {
  namespace telar::gui {

    struct ProgressCapsule {
      static constexpr std::size_t maximum_paints = ProgressRing::maximum_paints + 3;
      Rect area;
      Color color;
      float ratio = 1;
      PaneProgressState state = PaneProgressState::remove;
      float fraction = 0;
      float rotation = 0;
      bool compact = true;

      template <typename Visitor>
      TBC_GENERIC void visit(Visitor append) const {
        visit(PaintSink::of(append));
      }

      void visit(PaintSink append) const;
    };

  }
}
