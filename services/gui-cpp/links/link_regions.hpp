#pragma once

#include "link_grid.hpp"
#include "link_match.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

struct LinkRegion {
  std::uint16_t x;
  std::uint16_t y;
  std::uint16_t width;

  bool operator==(const LinkRegion &) const = default;
};

class LinkRegions {
public:
  struct Viewport {
    std::uint16_t columns;
    std::uint16_t rows;
  };

  LinkRegions(const LinkMatch &match, LinkGrid grid, std::span<const MetadataRun> runs)
      : LinkRegions(match, grid, runs, {.columns = grid.columns, .rows = grid.rows}) {}

  LinkRegions(const LinkMatch &match, LinkGrid grid, std::span<const MetadataRun> runs, Viewport viewport)
      : match_(match),
        grid_(grid),
        runs_(runs),
        viewport_{.columns = std::min(grid.columns, viewport.columns), .rows = std::min(grid.rows, viewport.rows)},
        row_(std::max(grid.scroll.offset, match.start.y)) {}

  [[nodiscard]] std::optional<LinkRegion> next() noexcept {
    if (grid_.columns == 0) {
      return {};
    }

    if (const auto index = match_.metadata_index) {
      return nextMetadataRun(*index);
    }

    while (row_ <= match_.end.y && row_ - grid_.scroll.offset < viewport_.rows) {
      const auto row = row_++;
      const auto relative = static_cast<std::uint32_t>(row - grid_.scroll.offset);
      auto right = row == match_.end.y ? match_.end.x : grid_.columns;
      if (relative < grid_.row_flags.size() && (grid_.row_flags[relative] & static_cast<Byte>(RowFlag::wide_padding)) != 0) {
        right = std::min<std::uint16_t>(right, grid_.columns - 1);
      }

      if (const auto area = clipped(relative, row == match_.start.y ? match_.start.x : 0, right)) {
        return area;
      }
    }

    return {};
  }

private:
  [[nodiscard]] std::optional<LinkRegion> nextMetadataRun(std::uint16_t link_index) noexcept {
    while (run_index_ < runs_.size()) {
      const auto &run = runs_[run_index_++];
      if (run.link_index != link_index) {
        continue;
      }

      const auto column = run.start % grid_.columns;
      if (const auto area = clipped(run.start / grid_.columns, column, column + run.len)) {
        return area;
      }
    }

    return {};
  }

  [[nodiscard]] std::optional<LinkRegion> clipped(std::uint32_t row, std::uint32_t left, std::uint32_t right) const noexcept {
    right = std::min<std::uint32_t>(right, viewport_.columns);
    if (row >= viewport_.rows || left >= right) {
      return {};
    }

    return LinkRegion{.x = static_cast<std::uint16_t>(left), .y = static_cast<std::uint16_t>(row), .width = static_cast<std::uint16_t>(right - left)};
  }

  const LinkMatch &match_;
  LinkGrid grid_;
  std::span<const MetadataRun> runs_;
  Viewport viewport_;
  std::uint64_t row_;
  std::size_t run_index_ = 0;
};

}
