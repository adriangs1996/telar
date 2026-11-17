export module telar.gui.foundation.core:geometry;

import std;

import :primitives;
import :configuration;

// Interface: core/geometry.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct Point {
      float x = 0;
      float y = 0;

      bool operator==(const Point&) const = default;
    };

    struct Rect {
      float x = 0;
      float y = 0;
      float width = 0;
      float height = 0;

      [[nodiscard]] float right() const noexcept;

      [[nodiscard]] float bottom() const noexcept;

      [[nodiscard]] bool contains(Point point) const noexcept;

      [[nodiscard]] Rect intersect(Rect other) const noexcept;

      // Replaces each rectangle with its intersection with area, as intersect does for one. A
      // caller with many rectangles makes one call per batch, so the loop stays in this unit,
      // where it vectorizes.
      static void intersectEach(std::span<Rect> rectangles, Rect area) noexcept;

      [[nodiscard]] Rect inset(float horizontal, float vertical) const noexcept;

      [[nodiscard]] bool empty() const noexcept;

      bool operator==(const Rect&) const = default;
    };

    struct Viewport {
      static constexpr float maximum_scale = 8;

      std::uint32_t width = 0;
      std::uint32_t height = 0;
      float scale = 1;
      std::uint32_t controls = 0;

      [[nodiscard]] bool valid() const noexcept;

      bool operator==(const Viewport&) const = default;
    };

  }
}

// Interface: core/metrics.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct CellMetrics {
      static constexpr float fallback_baseline = 14;

      float width = default_terminal_size.cell_width_px;
      float height = default_terminal_size.cell_height_px;
      float baseline = fallback_baseline;
      std::uint16_t pixels = static_cast<std::uint16_t>(FontConfiguration::default_size);

      bool operator==(const CellMetrics&) const = default;
    };

    struct ChromeMetrics {
      // Bar heights are specified for this terminal font size and scale with it.
      static constexpr float design_font_size = 14;
      static constexpr float maximum_text = 4096;
      static constexpr float logical_top_bar = 44;
      static constexpr float logical_status_bar = 38;
      static constexpr float logical_pane_header = 32;
      static constexpr float logical_pane_gap = 8;
      static constexpr float logical_pane_border = 1;
      static constexpr float title_ratio = 1;
      static constexpr float body_ratio = 0.93F;
      static constexpr float small_ratio = 0.855F;
      static constexpr float sans_line_ratio = 1.3F;
      static constexpr float minimum_text = 6;

      float ratio = 1;
      // The display scale times the chrome text's growth over the design font. Lengths that frame
      // chrome text (insets, marks, rows) follow it to keep their proportion to that text.
      float text_ratio = 1;
      float top_bar = logical_top_bar;
      float status_bar = logical_status_bar;
      float pane_header = logical_pane_header;
      std::uint16_t title = 14;
      std::uint16_t body = 13;
      std::uint16_t small = 12;

      static ChromeMetrics resolve(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells) noexcept;

      [[nodiscard]] float px(float logical) const noexcept;

      [[nodiscard]] float textPx(float logical) const noexcept;

      [[nodiscard]] static float lineHeight(std::uint16_t pixels) noexcept;
    };

    struct WindowGeometry {
      static constexpr float sidebar_minimum = Configuration::minimum_sidebar_width;
      static constexpr float sidebar_maximum = Configuration::maximum_sidebar_width;
      static constexpr float workbench_margin = 8;
      static constexpr float workbench_minimum_columns = 20;

      Rect navigation;
      Rect sidebar;
      Rect terminal;
      Rect status;
      bool rail = false;

      static WindowGeometry measure(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells) noexcept;

      static WindowGeometry measure(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells, const ChromeMetrics& chrome) noexcept;
    };

  }
}

// Interface: core/terminal_surface.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct TerminalSurface {
      Rect content;
      Point cell;
      std::uint64_t attachment_generation = 0;
      float scale = 1;

      bool operator==(const TerminalSurface&) const = default;
    };

  }
}

// Interface: core/cell_rectangle.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct CellRectangle {
      std::uint16_t x = 0;
      std::uint16_t y = 0;
      std::uint16_t width = 0;
      std::uint16_t height = 0;

      [[nodiscard]] std::uint32_t right() const noexcept;
      [[nodiscard]] std::uint32_t bottom() const noexcept;
      [[nodiscard]] bool empty() const noexcept;
      [[nodiscard]] CellRectangle inner(std::uint16_t margin) const noexcept;
      [[nodiscard]] CellRectangle intersect(CellRectangle other) const noexcept;
      [[nodiscard]] CellRectangle row(std::uint16_t index) const noexcept;

      bool operator==(const CellRectangle&) const = default;
    };

  }
}
