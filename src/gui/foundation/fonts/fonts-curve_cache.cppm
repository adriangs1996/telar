module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.fonts:curve_cache;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import :glyphs;
import telar.base.ds;

// Interface: terminal/glyphs/ink.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    void validateCell(Rect cell);

    // The rectangles of a drawn glyph, at most the capacity its glyph kind picks: Block, Box and
    // Braille below, instantiated for each in curve_cache.cpp.
    template <std::size_t Capacity>
    class Ink {
    public:
      explicit Ink(float coverage = 1) noexcept;

      [[nodiscard]] float coverage() const noexcept;
      [[nodiscard]] std::span<const Rect> rectangles() const noexcept;
      void push(Rect rectangle);
      void appendMerged(Rect rectangle);
      void translate(Point origin) noexcept;

    private:
      ds::Array<Rect, Capacity> rectangles_{};
      std::size_t count_ = 0;
      float coverage_;
    };

  }
}

// Interface: terminal/glyphs/block.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    class Block {
    public:
      using Paint = Ink<2>;

      [[nodiscard]] static Paint draw(Rect cell, std::uint32_t codepoint);

    private:
      static constexpr unsigned upper_left = 1;
      static constexpr unsigned upper_right = 2;
      static constexpr unsigned lower_left = 4;
      static constexpr unsigned lower_right = 8;

      [[nodiscard]] static Paint build(Rect cell, std::uint32_t codepoint);

      enum class Side : std::uint8_t {
        top,
        bottom,
        left,
        right,
      };

      static constexpr unsigned full_eighths = 8;
      static constexpr unsigned half_eighths = full_eighths / 2;

      [[nodiscard]] static float split(float extent, unsigned eighths) noexcept;
      [[nodiscard]] static Paint slab(Rect cell, Side side, unsigned eighths);
      [[nodiscard]] static Paint quadrantInk(Rect cell, std::uint8_t mask);
    };

  }
}

// Interface: terminal/glyphs/box_metrics.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    struct BoxMetrics {
      float width = 0;
      float height = 0;
      float light = 0;
      float heavy = 0;

      [[nodiscard]] static BoxMetrics resolve(Rect cell, float thickness);
    };

  }
}

// Interface: terminal/glyphs/box_edge_table.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    inline constexpr auto box_edge_table = ds::Array<BoxEdges, 128>{{
        {.right = BoxWeight::light, .left = BoxWeight::light},
        {.right = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .down = BoxWeight::light},
        {.up = BoxWeight::heavy, .down = BoxWeight::heavy},
        {},
        {},
        {},
        {},
        {},
        {},
        {},
        {},
        {.right = BoxWeight::light, .down = BoxWeight::light},
        {.right = BoxWeight::heavy, .down = BoxWeight::light},
        {.right = BoxWeight::light, .down = BoxWeight::heavy},
        {.right = BoxWeight::heavy, .down = BoxWeight::heavy},
        {.down = BoxWeight::light, .left = BoxWeight::light},
        {.down = BoxWeight::light, .left = BoxWeight::heavy},
        {.down = BoxWeight::heavy, .left = BoxWeight::light},
        {.down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy},
        {.up = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::light, .down = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .down = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .down = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::light, .down = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .down = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .down = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .down = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .down = BoxWeight::heavy},
        {.up = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.right = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::light},
        {.right = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.right = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::light},
        {.right = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.right = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.right = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.right = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.right = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::light, .right = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .down = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::light, .right = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::light, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::heavy, .right = BoxWeight::heavy, .down = BoxWeight::heavy, .left = BoxWeight::heavy},
        {},
        {},
        {},
        {},
        {.right = BoxWeight::double_line, .left = BoxWeight::double_line},
        {.up = BoxWeight::double_line, .down = BoxWeight::double_line},
        {.right = BoxWeight::double_line, .down = BoxWeight::light},
        {.right = BoxWeight::light, .down = BoxWeight::double_line},
        {.right = BoxWeight::double_line, .down = BoxWeight::double_line},
        {.down = BoxWeight::light, .left = BoxWeight::double_line},
        {.down = BoxWeight::double_line, .left = BoxWeight::light},
        {.down = BoxWeight::double_line, .left = BoxWeight::double_line},
        {.up = BoxWeight::light, .right = BoxWeight::double_line},
        {.up = BoxWeight::double_line, .right = BoxWeight::light},
        {.up = BoxWeight::double_line, .right = BoxWeight::double_line},
        {.up = BoxWeight::light, .left = BoxWeight::double_line},
        {.up = BoxWeight::double_line, .left = BoxWeight::light},
        {.up = BoxWeight::double_line, .left = BoxWeight::double_line},
        {.up = BoxWeight::light, .right = BoxWeight::double_line, .down = BoxWeight::light},
        {.up = BoxWeight::double_line, .right = BoxWeight::light, .down = BoxWeight::double_line},
        {.up = BoxWeight::double_line, .right = BoxWeight::double_line, .down = BoxWeight::double_line},
        {.up = BoxWeight::light, .down = BoxWeight::light, .left = BoxWeight::double_line},
        {.up = BoxWeight::double_line, .down = BoxWeight::double_line, .left = BoxWeight::light},
        {.up = BoxWeight::double_line, .down = BoxWeight::double_line, .left = BoxWeight::double_line},
        {.right = BoxWeight::double_line, .down = BoxWeight::light, .left = BoxWeight::double_line},
        {.right = BoxWeight::light, .down = BoxWeight::double_line, .left = BoxWeight::light},
        {.right = BoxWeight::double_line, .down = BoxWeight::double_line, .left = BoxWeight::double_line},
        {.up = BoxWeight::light, .right = BoxWeight::double_line, .left = BoxWeight::double_line},
        {.up = BoxWeight::double_line, .right = BoxWeight::light, .left = BoxWeight::light},
        {.up = BoxWeight::double_line, .right = BoxWeight::double_line, .left = BoxWeight::double_line},
        {.up = BoxWeight::light, .right = BoxWeight::double_line, .down = BoxWeight::light, .left = BoxWeight::double_line},
        {.up = BoxWeight::double_line, .right = BoxWeight::light, .down = BoxWeight::double_line, .left = BoxWeight::light},
        {.up = BoxWeight::double_line, .right = BoxWeight::double_line, .down = BoxWeight::double_line, .left = BoxWeight::double_line},
        {},
        {},
        {},
        {},
        {},
        {},
        {},
        {.left = BoxWeight::light},
        {.up = BoxWeight::light},
        {.right = BoxWeight::light},
        {.down = BoxWeight::light},
        {.left = BoxWeight::heavy},
        {.up = BoxWeight::heavy},
        {.right = BoxWeight::heavy},
        {.down = BoxWeight::heavy},
        {.right = BoxWeight::heavy, .left = BoxWeight::light},
        {.up = BoxWeight::light, .down = BoxWeight::heavy},
        {.right = BoxWeight::light, .left = BoxWeight::heavy},
        {.up = BoxWeight::heavy, .down = BoxWeight::light},
    }};

  }
}

// Interface: terminal/glyphs/box.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    class Box {
    public:
      static constexpr std::size_t stroke_capacity = 8;
      static constexpr std::size_t rectangle_capacity = 21;
      using Paint = Ink<rectangle_capacity>;

      [[nodiscard]] static Paint draw(std::uint32_t codepoint, Rect cell, float thickness);

    private:
      struct Junction {
        float backward_end = 0;
        float forward_start = 0;
      };

      struct Axis {
        float light_start = 0;
        float light_end = 0;
        float heavy_start = 0;
        float heavy_end = 0;
        float double_start = 0;
        float double_end = 0;

        [[nodiscard]] static Axis resolve(float extent, const BoxMetrics& metrics) noexcept;
        [[nodiscard]] Junction join(BoxWeight before, BoxWeight after, bool straight) const noexcept;
      };

      struct Interval {
        float left = 0;
        float right = 0;
      };

      explicit Box(BoxMetrics metrics) noexcept;

      void add(float left, float top, float right, float bottom);
      void intersection(const BoxEdges& edges);
      void upperArm(const BoxEdges& edges, float bottom);
      void rightArm(const BoxEdges& edges, float left);
      void lowerArm(const BoxEdges& edges, float top);
      void leftArm(const BoxEdges& edges, float right);
      void dashes(std::uint32_t codepoint);
      [[nodiscard]] static unsigned dashCount(std::uint32_t codepoint) noexcept;
      void addDash(bool vertical, float center, float start, float end, float thickness);
      [[nodiscard]] static Paint unite(std::span<const Rect> strokes);
      static void uniteBand(Paint& result, std::span<const Rect> strokes, float top, float bottom);

      BoxMetrics metrics_;
      Axis x_;
      Axis y_;
      Ink<stroke_capacity> strokes_;
    };

  }
}

// Interface: terminal/glyphs/box_curve.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    class BoxCurve {
    public:
      enum class Shape : std::uint8_t {
        rounded_down_right,
        rounded_down_left,
        rounded_up_left,
        rounded_up_right,
        rising_diagonal,
        falling_diagonal,
        diagonal_cross,
        // Powerline separators U+E0B0..U+E0BF, in code point order. They span the whole cell
        // so they meet the cell background at any line height.
        powerline_right_triangle,
        powerline_right_angle,
        powerline_left_triangle,
        powerline_left_angle,
        powerline_right_half_circle,
        powerline_right_arc,
        powerline_left_half_circle,
        powerline_left_arc,
        powerline_lower_left_triangle,
        powerline_backslash,
        powerline_lower_right_triangle,
        powerline_forwardslash,
        powerline_upper_left_triangle,
        powerline_forwardslash_redundant,
        powerline_upper_right_triangle,
        powerline_backslash_redundant,
      };

      static constexpr std::size_t shape_count = 23;

      BoxCurve(Shape shape, Rect cell, float thickness);
      [[nodiscard]] static ds::Option<Shape> shape(std::uint32_t codepoint) noexcept;
      void rasterize(AlphaRaster raster) const;

    private:
      static constexpr std::size_t curve_segments = 16;
      static constexpr std::size_t point_capacity = curve_segments + 3;

      struct PixelBounds {
        std::size_t left = 0;
        std::size_t top = 0;
        std::size_t right = 0;
        std::size_t bottom = 0;
      };

      void powerline(Shape shape) noexcept;
      void halfEllipse(bool bulges_right) noexcept;
      [[nodiscard]] PixelBounds rasterBounds(const AlphaRaster& raster, Point scale) const noexcept;
      [[nodiscard]] float distanceSquared(Point point) const noexcept;
      [[nodiscard]] bool contains(Point point) const noexcept;
      [[nodiscard]] static float segmentDistance(Point point, const ds::Array<Point, 2>& segment) noexcept;

      BoxMetrics metrics_;
      ds::Array<Point, point_capacity> points_{};
      std::size_t count_ = 0;
      bool cross_ = false;
      // Filled shapes close the polygon and cover its interior; the others stroke a polyline.
      bool filled_ = false;
    };

  }
}

// Interface: terminal/glyphs/braille.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    class Braille {
    public:
      static constexpr std::size_t dot_count = 8;
      using Paint = Ink<dot_count>;

      [[nodiscard]] static Paint draw(Rect cell, std::uint8_t dots);

    private:
      static constexpr int columns = 2;
      static constexpr int rows = 4;
      static constexpr int horizontal_divisions = 2 * columns;
      static constexpr int vertical_divisions = 2 * rows;

      struct Grid {
        ds::Array<float, columns> x{};
        ds::Array<float, rows> y{};
        float diameter = 0;
      };

      [[nodiscard]] static Grid fractionalGrid(Rect cell) noexcept;
      [[nodiscard]] static Grid integerGrid(Rect cell) noexcept;
    };

    extern template class Ink<2>;
    extern template class Ink<Box::stroke_capacity>;
    extern template class Ink<Box::rectangle_capacity>;

  }
}

// Interface: terminal/glyphs/curve_cache.cppm
export {
  namespace telar::gui::inline foundation::inline fonts::glyphs {

    // Generic over the payload the renderer caches; looked up once per drawn curve glyph.
    template <std::movable Payload>
    class TBC_GENERIC CurveCache {
    public:
      static constexpr std::size_t capacity = 56;
      static constexpr std::uint16_t raster_limit = 256;
      static constexpr std::uint16_t fallback_width = 16;
      static constexpr std::uint16_t fallback_height = 32;

      template <typename Builder>
        requires std::invocable<Builder> && std::same_as<std::invoke_result_t<Builder>, ds::Option<Payload>>
      [[nodiscard]] Payload* resolve(const BoxMetrics& metrics, BoxCurve::Shape shape, Builder&& build) {
        const Key key{.width_bits = std::bit_cast<std::uint32_t>(metrics.width), .height_bits = std::bit_cast<std::uint32_t>(metrics.height), .thickness_bits = std::bit_cast<std::uint32_t>(metrics.light), .shape = shape};

        for (auto& entry : entries_.viewMut().first(count_)) {
          if (entry.key == key) {
            return entry.payload ? &entry.payload.getMut() : nullptr;
          }
        }

        if (count_ == capacity) {
          return nullptr;
        }

        auto& entry = entries_.atMut(count_++);

        entry.key = key;
        entry.payload = std::invoke(std::forward<Builder>(build));

        return entry.payload ? &entry.payload.getMut() : nullptr;
      }

      inline void reset() noexcept {
        for (auto& entry : entries_.viewMut().first(count_)) {
          entry.payload.reset();
        }

        count_ = 0;
      }

      [[nodiscard]] inline std::size_t size() const noexcept {
        return count_;
      }

    private:
      struct Key {
        std::uint32_t width_bits = 0;
        std::uint32_t height_bits = 0;
        std::uint32_t thickness_bits = 0;
        BoxCurve::Shape shape = BoxCurve::Shape::rounded_down_right;

        bool operator==(const Key&) const = default;
      };

      struct Entry {
        Key key;
        ds::Option<Payload> payload;
      };

      ds::Array<Entry, capacity> entries_{};
      std::size_t count_ = 0;
    };

  }
}
