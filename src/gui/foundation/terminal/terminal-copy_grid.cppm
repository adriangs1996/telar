export module telar.gui.foundation.terminal:copy_grid;

import std;

import telar.base.memory.allocators;
import telar.wire.clipboard;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import :screen;

// Interface: terminal/copy_grid.cppm
export {
  namespace telar::gui::inline foundation::inline terminal {

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
  namespace telar::gui::inline foundation::inline terminal {

    class CopyRangeParser {
    public:
      static CopySelection parse(std::uint64_t pane_id, std::string_view text);
    };

  }
}
