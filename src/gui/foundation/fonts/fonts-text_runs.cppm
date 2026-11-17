module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.fonts:text_runs;

import std;

import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.gui.foundation.terminal;
import :face;

// Interface: terminal/text_runs.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    template <typename Coverage>
    concept LigatureRoles = requires(const Coverage& coverage, std::string_view text) {
      { coverage.role(text) } -> std::same_as<fonts::LigatureRole>;
    };

    struct TextRun {
      std::size_t count = 1;
      bool together = false;
    };

    template <Allocator Memory>
    class TextRuns {
    public:
      static constexpr std::size_t maximum_cells = 128;
      static constexpr std::size_t maximum_bytes = maximum_cells * CellValue::text_capacity;
      static constexpr std::size_t maximum_glyphs = 2 * maximum_cells;

      explicit TextRuns(Memory& memory);

      void reserve(std::size_t columns);

      void clear() noexcept;

      // Generic over the caller's ligature coverage; called once per cell of a shaped row.
      template <LigatureRoles Coverage>
      TBC_GENERIC void append(const Coverage& coverage, const CellValue& cell, bool alone) {
        const auto role = alone || !shapeable(cell) ? fonts::LigatureRole::none : coverage.role(cell.utf8());
        const auto joins = role != fonts::LigatureRole::none && !columns_.empty() && columns_.back().role != fonts::LigatureRole::none && inkStyle(previous_.style) == inkStyle(cell.style) && !typographic(previous_, cell);

        columns_.push_back({.role = role, .joins = joins});
        previous_ = cell;
        inputs_ += static_cast<std::size_t>(role == fonts::LigatureRole::input);
      }

      void close(std::uint16_t reach) noexcept;

      [[nodiscard]] TextRun at(std::size_t start) const noexcept;

    private:
      static constexpr auto far = std::numeric_limits<std::uint16_t>::max();

      struct Column {
        fonts::LigatureRole role = fonts::LigatureRole::none;
        bool joins = false;
        bool kept = false;
        std::uint16_t since = far;
      };

      [[nodiscard]] static std::uint16_t distanceFromInput(fonts::LigatureRole role, std::uint16_t distance) noexcept;

      [[nodiscard]] static bool shapeable(const CellValue& cell) noexcept;

      [[nodiscard]] static CellStyle inkStyle(CellStyle style) noexcept;

      [[nodiscard]] static bool typographic(const CellValue& previous, const CellValue& next) noexcept;

      Vector<Column, Memory> columns_;
      CellValue previous_;
      std::size_t inputs_ = 0;
    };

    extern template class TextRuns<Memory>;
    extern template class TextRuns<ConcurrentMemory>;

  }
}
