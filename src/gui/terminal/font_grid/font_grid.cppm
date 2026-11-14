export module telar.gui.terminal.font_grid;

import std;

export import telar.gui.core.metrics;
import telar.base.memory.allocators;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.wire.clipboard;
import telar.wire.vocabulary;

// Interface: terminal/copy_grid.cppm
export {
  namespace telar::gui {

    using CopyPoint = CellPosition;

    enum class CopyDirection : std::uint8_t {
      forward,
      backward,
    };
    enum class CopyGranularity : std::uint8_t {
      character,
      word,
      line,
    };
    enum class CopyWordClass : std::uint8_t {
      space,
      word,
      punctuation,
    };

    struct CopyGrid {
      std::span<const CellValue> cells;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      Scroll scroll;

      [[nodiscard]] std::uint32_t maximumOffset() const noexcept;
      [[nodiscard]] std::uint32_t lastRow() const noexcept;
      [[nodiscard]] const CellValue* cell(CopyPoint point) const noexcept;
      [[nodiscard]] static bool whitespace(char byte) noexcept;
      [[nodiscard]] std::optional<CopyWordClass> wordClass(CopyPoint point) const noexcept;
      [[nodiscard]] CopyPoint step(CopyPoint point, CopyDirection direction) const noexcept;
      [[nodiscard]] bool blankRow(std::uint32_t absolute_row) const noexcept;
      [[nodiscard]] std::array<CopyPoint, 2> pointerSpan(CopyPoint point, CopyGranularity granularity) const noexcept;

    private:
      [[nodiscard]] bool pointerWord(CopyPoint point) const noexcept;
    };

    template <Allocator Memory>
    CopyGrid copyGrid(const Screen<Memory>& screen) noexcept;

    extern template CopyGrid copyGrid<Memory>(const Screen<Memory>& screen) noexcept;
    extern template CopyGrid copyGrid<ConcurrentMemory>(const Screen<ConcurrentMemory>& screen) noexcept;

    // Where a wheel step over a screen goes: to its application as a mouse report, to its
    // application as cursor keys (alternate scroll, on the alternate screen scrolled to its end), or
    // to the scrollback.
    enum class WheelRoute : std::uint8_t {
      report,
      keys,
      scroll,
    };

    template <Allocator Memory>
    WheelRoute wheelRoute(const Screen<Memory>& screen) noexcept;

    extern template WheelRoute wheelRoute<Memory>(const Screen<Memory>& screen) noexcept;
    extern template WheelRoute wheelRoute<ConcurrentMemory>(const Screen<ConcurrentMemory>& screen) noexcept;

  }
}

// Interface: terminal/copy_range.cppm
export {
  namespace telar::gui {

    class CopyRangeParser {
    public:
      static CopySelection parse(std::uint64_t pane_id, std::string_view text);
    };

  }
}

// Interface: terminal/font_grid.cppm
export {
  namespace telar::gui {

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
  namespace telar::gui::glyphs {

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
