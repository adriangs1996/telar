module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.drawing:progress;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.core;
import :rounded_rectangle;
import telar.base.ds;

// Interface: graphics/progress_ring.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

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
      ds::Option<Color> track = ds::none;

      template <typename Visitor>
      TBC_GENERIC void visit(Visitor visitor) const {
        visit(PaintSink::of(visitor));
      }

      void visit(PaintSink visitor) const;

    private:
      [[nodiscard]] static Point endpoint(float fraction) noexcept;

      static const ds::Array<Point, segments> circle;
    };

  }
}

// Interface: graphics/progress_capsule.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

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

// Interface: presentation/progress_geometry.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

    struct ProgressGeometry {
      static constexpr float ring_side = 14;
      static constexpr float padding = 5;
      static constexpr float height = 20;
      static constexpr float ring_inset = 4;
      static constexpr float background_alpha = 0.1F;
      static constexpr float mark_stroke_ratio = 0.1F;
      static constexpr float mark_top_ratio = 0.32F;
      static constexpr float pause_height_ratio = 0.36F;
      static constexpr float error_height_ratio = 0.24F;
      static constexpr float error_dot_ratio = 0.63F;
      static constexpr ds::Array pause_offsets{-1.5F, 0.5F};

      Rect background;
      Rect ring;
      ds::Array<Rect, 2> marks{};
      std::size_t mark_count = 0;
      float mark_radius = 0;

      [[nodiscard]] static constexpr float compactWidth(float ratio = 1) noexcept {
        const auto scaled_padding = padding * ratio;

        return (ring_side * ratio) + (2 * scaled_padding);
      }

      [[nodiscard]] static ProgressGeometry derive(Rect area, float ratio, PaneProgressState state, bool compact = true) noexcept;
    };

  }
}
