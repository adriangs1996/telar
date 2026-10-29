#pragma once

#include "copy_grid.hpp"
#include "selection.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

struct CopyPointer {
  CopyPoint start;
  CopyPoint end;
  CopyGranularity granularity = CopyGranularity::character;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;

  bool operator==(const CopyPointer &) const = default;
};

struct CopyState {
  std::uint64_t pane_id = 0;
  CopyPoint cursor;
  std::optional<CopyPointer> pointer = std::nullopt;
  std::optional<CopyPoint> anchor = std::nullopt;
  bool linewise = false;
  std::uint32_t entry_offset = 0;
  std::uint32_t viewport_offset = 0;
  CopyDirection search_direction = CopyDirection::forward;
  std::uint16_t match_index = 0;

  bool operator==(const CopyState &) const = default;

  [[nodiscard]] std::optional<CopySelection> selectionRequest() const noexcept {
    if (!anchor) {
      return {};
    }

    return CopySelection{.pane_id = pane_id, .start_x = anchor->x, .start_y = anchor->y, .end_x = cursor.x, .end_y = cursor.y, .linewise = linewise};
  }

  void horizontal(const CopyGrid &grid, std::int32_t delta) noexcept {
    const auto columns = grid.columns;
    const auto last = columns == 0 ? 0 : columns - 1;
    cursor.x = static_cast<std::uint16_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(cursor.x) + delta, 0, last));
  }

  void vertical(std::int32_t delta, const CopyGrid &grid) noexcept {
    cursor.y = static_cast<std::uint32_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(cursor.y) + delta, 0, grid.lastRow()));
    reveal(grid);
  }

  void reveal(const CopyGrid &grid) noexcept {
    if (cursor.y < viewport_offset) {
      viewport_offset = cursor.y;
    } else if (static_cast<std::uint64_t>(cursor.y) >= static_cast<std::uint64_t>(viewport_offset) + grid.rows) {
      viewport_offset = cursor.y - std::min<std::uint32_t>(cursor.y, grid.rows == 0 ? 0 : grid.rows - 1);
    }

    viewport_offset = std::min(viewport_offset, grid.maximumOffset());
  }

  void toggleSelection(bool whole_lines) noexcept {
    if (anchor && linewise == whole_lines) {
      static_cast<void>(clearSelection());

      return;
    }

    anchor = cursor;
    linewise = whole_lines;
  }

  bool clearSelection() noexcept {
    if (!anchor) {
      return false;
    }

    anchor.reset();
    linewise = false;

    return true;
  }

  void beginPointer(CopyGranularity granularity, const CopyGrid &grid) noexcept {
    const auto span = grid.pointerSpan(cursor, granularity);
    pointer = CopyPointer{.start = span[0], .end = span[1], .granularity = granularity, .columns = grid.columns, .rows = grid.rows};
    anchor = granularity == CopyGranularity::character ? std::nullopt : std::optional{span[0]};
    cursor = span[1];
    linewise = granularity == CopyGranularity::line;
  }

  void movePointer(CopyPoint point, const CopyGrid &grid) noexcept {
    if (!pointer || grid.columns == 0 || grid.rows == 0) {
      return;
    }

    point.x = std::min<std::uint16_t>(point.x, grid.columns - 1);
    point.y = std::clamp(point.y, grid.scroll.offset, grid.scroll.offset + grid.rows - 1);
    const auto span = grid.pointerSpan(point, pointer->granularity);
    const auto backwards = point < pointer->start;
    anchor = backwards ? pointer->end : pointer->start;
    cursor = backwards ? span[0] : span[1];
    if (pointer->granularity == CopyGranularity::character && span[0] == pointer->start && span[1] == pointer->end) {
      anchor.reset();
    }
  }

  void onFrame(std::uint32_t previous_offset, Scroll scroll) noexcept {
    if (scroll.offset < previous_offset && viewport_offset == previous_offset) {
      const auto pruned = previous_offset - scroll.offset;
      cursor.y -= std::min(cursor.y, pruned);
      if (anchor) {
        anchor->y -= std::min(anchor->y, pruned);
      }

      if (pointer) {
        pointer->start.y -= std::min(pointer->start.y, pruned);
        pointer->end.y -= std::min(pointer->end.y, pruned);
      }
    }

    const auto last = scroll.total_rows == 0 ? 0 : scroll.total_rows - 1;
    cursor.y = std::min(cursor.y, last);
    if (anchor) {
      anchor->y = std::min(anchor->y, last);
    }

    if (pointer) {
      pointer->start.y = std::min(pointer->start.y, last);
      pointer->end.y = std::min(pointer->end.y, last);
    }

    viewport_offset = scroll.offset;
  }

  void gotoMatch(std::uint16_t index, std::span<const PaneMatch> matches, const CopyGrid &grid) noexcept {
    if (index >= matches.size() || matches[index].len == 0) {
      return;
    }

    const auto &match = matches[index];
    match_index = index;
    anchor = CopyPoint{.x = match.x, .y = match.y};
    linewise = false;
    cursor = {.x = static_cast<std::uint16_t>(static_cast<std::uint32_t>(match.x) + match.len - 1), .y = std::min(match.y, grid.lastRow())};
    reveal(grid);
  }

  void applyMatches(std::span<const PaneMatch> matches, const CopyGrid &grid) noexcept {
    if (matches.empty()) {
      return;
    }

    std::size_t selected = search_direction == CopyDirection::forward ? 0 : matches.size() - 1;
    if (search_direction == CopyDirection::forward) {
      for (std::size_t index = 0; index < matches.size(); ++index) {
        if (cursor < CopyPoint{.x = matches[index].x, .y = matches[index].y}) {
          selected = index;
          break;
        }
      }
    } else {
      for (std::size_t index = matches.size(); index-- > 0;) {
        if (CopyPoint{.x = matches[index].x, .y = matches[index].y} < cursor) {
          selected = index;
          break;
        }
      }
    }

    gotoMatch(static_cast<std::uint16_t>(selected), matches, grid);
  }

  [[nodiscard]] CellSelection selection(const CopyGrid &grid) const noexcept {
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
};

}
