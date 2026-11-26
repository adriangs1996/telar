export module telar.gui.foundation.drawing:rounded_rectangle;

import std;

import telar.gui.foundation.core;

// Interface: graphics/rounded_rectangle.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

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

namespace telar::gui::inline foundation::inline drawing {

  // A caller's paint visitor behind a function pointer, so that the shapes are computed in placeholder.cpp.
  struct PaintSink {
    void* context;
    void (*call)(void* context, const RoundedRectanglePaint& paint);

    // Generic over the caller's visitor, so it stays here.
    template <typename Visitor>
    [[tbc::generic]] static PaintSink of(Visitor& visitor) noexcept {
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
