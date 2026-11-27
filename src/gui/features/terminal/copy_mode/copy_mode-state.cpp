module telar.gui.features.terminal.copy_mode;

import std;
import telar.gui.foundation.terminal;
import telar.wire.clipboard;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::copy_mode {

  ds::Option<CopySelection> CopyState::selectionRequest() const noexcept {
    if (!anchor) {
      return {};
    }

    return CopySelection{.pane_id = pane_id, .start_x = anchor->x, .start_y = anchor->y, .end_x = cursor.x, .end_y = cursor.y, .linewise = linewise};
  }

  void CopyState::horizontal(const CopyGrid& grid, std::int32_t delta) noexcept {
    const auto columns = grid.columns;
    const auto last = columns == 0 ? 0 : columns - 1;

    cursor.x = static_cast<std::uint16_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(cursor.x) + delta, 0, last));
  }

  void CopyState::vertical(std::int32_t delta, const CopyGrid& grid) noexcept {
    cursor.y = static_cast<std::uint32_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(cursor.y) + delta, 0, grid.lastRow()));
    reveal(grid);
  }

  void CopyState::reveal(const CopyGrid& grid) noexcept {
    if (cursor.y < viewport_offset) {
      viewport_offset = cursor.y;
    } else if (static_cast<std::uint64_t>(cursor.y) >= static_cast<std::uint64_t>(viewport_offset) + grid.rows) {
      viewport_offset = cursor.y - std::min<std::uint32_t>(cursor.y, grid.rows == 0 ? 0 : grid.rows - 1);
    }

    viewport_offset = std::min(viewport_offset, grid.maximumOffset());
  }

  void CopyState::toggleSelection(bool whole_lines) noexcept {
    if (anchor && linewise == whole_lines) {
      static_cast<void>(clearSelection());

      return;
    }

    anchor = cursor;
    linewise = whole_lines;
  }

  bool CopyState::clearSelection() noexcept {
    if (!anchor) {
      return false;
    }

    anchor.reset();
    linewise = false;

    return true;
  }

  void CopyState::beginPointer(CopyGranularity granularity, const CopyGrid& grid) noexcept {
    const auto span = grid.pointerSpan(cursor, granularity);

    pointer = CopyPointer{.start = span[0], .end = span[1], .granularity = granularity, .columns = grid.columns, .rows = grid.rows};
    anchor = granularity == CopyGranularity::character ? ds::none : ds::Option{span[0]};
    cursor = span[1];
    linewise = granularity == CopyGranularity::line;
  }

  void CopyState::movePointer(CopyPoint point, const CopyGrid& grid) noexcept {
    if (!pointer || grid.columns == 0 || grid.rows == 0) {
      return;
    }

    point.x = std::min<std::uint16_t>(point.x, grid.columns - 1);
    point.y = std::min(point.y, grid.lastRow());
    const auto span = grid.pointerSpan(point, pointer->granularity);
    const auto backwards = point < pointer->start;

    anchor = backwards ? pointer->end : pointer->start;
    cursor = backwards ? span[0] : span[1];
    if (pointer->granularity == CopyGranularity::character && span[0] == pointer->start && span[1] == pointer->end) {
      anchor.reset();
    }
  }

  void CopyState::onFrame(std::uint32_t previous_offset, Scroll scroll) noexcept {
    if (scroll.offset < previous_offset && viewport_offset == previous_offset) {
      const auto pruned = previous_offset - scroll.offset;

      cursor.y -= std::min(cursor.y, pruned);
      if (anchor) {
        anchor.getMut().y -= std::min(anchor->y, pruned);
      }

      if (pointer) {
        pointer.getMut().start.y -= std::min(pointer->start.y, pruned);
        pointer.getMut().end.y -= std::min(pointer->end.y, pruned);
      }
    }

    const auto last = scroll.total_rows == 0 ? 0 : scroll.total_rows - 1;

    cursor.y = std::min(cursor.y, last);
    if (anchor) {
      anchor.getMut().y = std::min(anchor->y, last);
    }

    if (pointer) {
      pointer.getMut().start.y = std::min(pointer->start.y, last);
      pointer.getMut().end.y = std::min(pointer->end.y, last);
    }

    viewport_offset = scroll.offset;
  }

  void CopyState::gotoMatch(std::uint16_t index, std::span<const PaneMatch> matches, const CopyGrid& grid) noexcept {
    if (index >= matches.size() || matches[index].len == 0) {
      return;
    }

    const auto& match = matches[index];

    match_index = index;
    cursor = {.x = match.x, .y = std::min(match.y, grid.lastRow())};
    revealWithMargin(grid);
  }

  void CopyState::revealWithMargin(const CopyGrid& grid) noexcept {
    const auto rows = static_cast<std::uint32_t>(grid.rows);
    const auto margin = std::min<std::uint32_t>(std::max<std::uint32_t>(2, rows / 5), rows / 2);
    const auto top = static_cast<std::uint64_t>(viewport_offset) + margin;
    const auto bottom = static_cast<std::uint64_t>(viewport_offset) + rows - margin;
    if (cursor.y < top || cursor.y >= bottom) {
      viewport_offset = cursor.y - std::min<std::uint32_t>(cursor.y, rows / 2);
    }

    viewport_offset = std::min(viewport_offset, grid.maximumOffset());
  }

  void CopyState::applyMatches(std::span<const PaneMatch> matches, const CopyGrid& grid, bool inclusive) noexcept {
    if (matches.empty()) {
      return;
    }

    std::size_t selected = search_direction == CopyDirection::forward ? 0 : matches.size() - 1;

    if (search_direction == CopyDirection::forward) {
      for (std::size_t index = 0; index < matches.size(); ++index) {
        const CopyPoint start{.x = matches[index].x, .y = matches[index].y};
        if (cursor < start || (inclusive && cursor == start)) {
          selected = index;
          break;
        }
      }
    } else {
      for (std::size_t index = matches.size(); index-- > 0;) {
        const CopyPoint start{.x = matches[index].x, .y = matches[index].y};
        if (start < cursor || (inclusive && start == cursor)) {
          selected = index;
          break;
        }
      }
    }

    gotoMatch(static_cast<std::uint16_t>(selected), matches, grid);
  }

  CellSelection CopyState::selection(const CopyGrid& grid) const noexcept {
    if (!anchor || grid.columns == 0 || grid.rows == 0) {
      return {};
    }

    auto first = std::min(*anchor, cursor);
    auto last = std::max(*anchor, cursor);
    const auto viewport_last = static_cast<std::uint64_t>(grid.scroll.offset) + grid.rows - 1;
    if (last.y < grid.scroll.offset || first.y > viewport_last) {
      return {};
    }

    if (linewise || first.y < grid.scroll.offset) {
      first.x = 0;
    }

    if (linewise || last.y > viewport_last) {
      last.x = grid.columns - 1;
    }

    first.y = std::max(first.y, grid.scroll.offset) - grid.scroll.offset;
    last.y = static_cast<std::uint32_t>(std::min<std::uint64_t>(last.y, viewport_last)) - grid.scroll.offset;

    return {.anchor = static_cast<int>((first.y * grid.columns) + first.x), .head = static_cast<int>((last.y * grid.columns) + last.x)};
  }

}
