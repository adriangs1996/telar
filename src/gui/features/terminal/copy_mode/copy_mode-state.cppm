// Where copy mode stands in a pane: its cursor, the selection it stretches and the matches of
// its search.
export module telar.gui.features.terminal.copy_mode:state;

import std;

import telar.gui.foundation.terminal;
import telar.wire.clipboard;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: terminal/copy_state.cppm
export {
  namespace telar::gui::features::terminal::copy_mode {

    struct CopyPointer {
      CopyPoint start;
      CopyPoint end;
      CopyGranularity granularity = CopyGranularity::character;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;

      bool operator==(const CopyPointer&) const = default;
    };

    struct CopyState {
      std::uint64_t pane_id = 0;
      CopyPoint cursor;
      ds::Option<CopyPointer> pointer = ds::none;
      ds::Option<CopyPoint> anchor = ds::none;
      bool linewise = false;
      std::uint32_t entry_offset = 0;
      std::uint32_t viewport_offset = 0;
      CopyDirection search_direction = CopyDirection::forward;
      std::uint16_t match_index = 0;

      bool operator==(const CopyState&) const = default;

      [[nodiscard]] ds::Option<CopySelection> selectionRequest() const noexcept;

      void horizontal(const CopyGrid& grid, std::int32_t delta) noexcept;

      void vertical(std::int32_t delta, const CopyGrid& grid) noexcept;

      void reveal(const CopyGrid& grid) noexcept;

      void toggleSelection(bool whole_lines) noexcept;

      bool clearSelection() noexcept;

      void beginPointer(CopyGranularity granularity, const CopyGrid& grid) noexcept;

      void movePointer(CopyPoint point, const CopyGrid& grid) noexcept;

      void onFrame(std::uint32_t previous_offset, Scroll scroll) noexcept;

      // To match `index`, the cursor on its first cell as vim's search puts it, a selection under
      // way stretched there and none begun; the view centred on it unless it is well inside.
      void gotoMatch(std::uint16_t index, std::span<const PaneMatch> matches, const CopyGrid& grid) noexcept;

      // Shows the cursor clear of the view's edges, where a pinned separator and a docked line
      // cover rows: a row outside the middle of the view, a fifth of it from each edge and at least
      // two rows, comes to the view's middle.
      void revealWithMargin(const CopyGrid& grid) noexcept;

      // To the first match past the cursor that way, or, `inclusive`, from the cursor's own cell.
      void applyMatches(std::span<const PaneMatch> matches, const CopyGrid& grid, bool inclusive = false) noexcept;

      [[nodiscard]] CellSelection selection(const CopyGrid& grid) const noexcept;
    };

  }
}
