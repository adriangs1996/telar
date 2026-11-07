module;
#include <concepts>
#include <cstring>
#include <exception>
#include <memory>
#include <type_traits>
#include <cstdio>
#include <string>
#include <variant>
#include <vector>
#include <bit>
#include <stdexcept>
#include <compare>
#include <tuple>
#include <chrono>
#include <cstdlib>
#include <mutex>
#include <new>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <string_view>
#include <limits>
#include <optional>
#include <array>

#include <utility>

#include <span>

export module telar.gui.links.link_hover;

export import telar.gui.core.metrics;
export import telar.gui.links.cell_links;


export import telar.gui.core.unicode_scalar;


export import telar.gui.links.path_expansion;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: links/link_hit.cppm
export {
namespace telar::gui {

struct LinkHit {
  std::uint64_t pane_id = 0;
  std::uint64_t generation = 0;
  TabLocation location;
  Rect content;
  std::uint32_t scroll_offset = 0;
  Rect area;
  LinkMatch match;

  [[nodiscard]] bool operator==(const LinkHit &other) const noexcept {
    return pane_id == other.pane_id && generation == other.generation && sameTab(location, other.location) && content == other.content && scroll_offset == other.scroll_offset && area == other.area && match == other.match;
  }
};

}
}

// Interface: links/link_gesture.cppm
export {
namespace telar::gui {

class LinkGesture {
public:
  inline void begin(const LinkHit &hit, ViewVersion version) {
    pressed_ = hit;
    version_ = version;
  }

  inline void validate(const std::optional<LinkHit> &current, ViewVersion version) {
    if (pressed_ && (version_ != version || current != pressed_)) {
      cancel();
    }
  }

  [[nodiscard]] inline std::optional<LinkHit> finish(const std::optional<LinkHit> &current, ViewVersion version) {
    validate(current, version);

    return std::exchange(pressed_, std::nullopt);
  }

  inline void cancel() noexcept {
    pressed_.reset();
  }

  [[nodiscard]] inline bool active() const noexcept {
    return pressed_.has_value();
  }

private:
  std::optional<LinkHit> pressed_;
  ViewVersion version_;
};

}
}

// Interface: links/link_hover.cppm
export {
namespace telar::gui {

struct LinkPresentation {
  TerminalSurface surface;
  std::optional<LinkHit> link;
  std::optional<Rect> cover;
};

class LinkHover {
public:
  [[nodiscard]] inline bool assign(std::optional<LinkHit> hit, const TerminalSurface &surface, bool frame_presented) {
    const auto changed = hit != current_;
    current_ = std::move(hit);
    if (current_ && frame_presented && surfaceVisible(surface)) {
      shown_ = current_;
    }

    return changed;
  }

  inline void clear() noexcept {
    current_.reset();
    shown_.reset();
  }

  [[nodiscard]] inline bool openable(const TerminalSurface &surface) const noexcept {
    return current_ && current_ == shown_ && surfaceVisible(surface);
  }

  [[nodiscard]] inline bool surfaceVisible(const TerminalSurface &surface) const noexcept {
    return shown_surface_ && *shown_surface_ == surface;
  }

  [[nodiscard]] inline bool covers(Point point) const noexcept {
    return shown_cover_ && shown_cover_->contains(point);
  }

  [[nodiscard]] inline bool needsPresentation(const TerminalSurface &surface, const std::optional<Rect> &cover) const noexcept {
    return !surfaceVisible(surface) || shown_ != current_ || shown_cover_ != cover;
  }

  [[nodiscard]] inline LinkPresentation prepare(const TerminalSurface &surface, std::optional<Rect> cover) const {
    return {.surface = surface, .link = current_, .cover = cover};
  }

  inline void present(const LinkPresentation &frame, bool delivered = true) {
    if (delivered) {
      shown_ = frame.link;
      shown_surface_ = frame.surface;
      shown_cover_ = frame.cover;
    }
  }

  [[nodiscard]] inline const std::optional<LinkHit> &current() const noexcept {
    return current_;
  }

private:
  std::optional<LinkHit> current_;
  std::optional<LinkHit> shown_;
  std::optional<TerminalSurface> shown_surface_;
  std::optional<Rect> shown_cover_;
};

}
}

// Interface: links/link_opening.cppm
export {
namespace telar::gui {

class LinkOpening {
public:
  [[nodiscard]] inline bool request(const LinkTarget &target) {
    if (active_) {
      pending_ = target;

      return false;
    }

    active_ = true;

    return true;
  }

  [[nodiscard]] inline std::optional<LinkTarget> complete() {
    auto next = std::move(pending_);
    pending_.reset();
    active_ = next.has_value();

    return next;
  }

  inline void schedulingFailed() noexcept {
    active_ = false;
  }

  [[nodiscard]] inline bool active() const noexcept {
    return active_;
  }

private:
  bool active_ = false;
  std::optional<LinkTarget> pending_;
};

}
}

// Interface: links/link_regions.cppm
export {
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

  inline LinkRegions(const LinkMatch &match, LinkGrid grid, std::span<const MetadataRun> runs)
      : LinkRegions(match, grid, runs, {.columns = grid.columns, .rows = grid.rows}) {}

  inline LinkRegions(const LinkMatch &match, LinkGrid grid, std::span<const MetadataRun> runs, Viewport viewport)
      : match_(match),
        grid_(grid),
        runs_(runs),
        viewport_{.columns = std::min(grid.columns, viewport.columns), .rows = std::min(grid.rows, viewport.rows)},
        row_(std::max(grid.scroll.offset, match.start.y)) {}

  [[nodiscard]] inline std::optional<LinkRegion> next() noexcept {
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
  [[nodiscard]] inline std::optional<LinkRegion> nextMetadataRun(std::uint16_t link_index) noexcept {
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

  [[nodiscard]] inline std::optional<LinkRegion> clipped(std::uint32_t row, std::uint32_t left, std::uint32_t right) const noexcept {
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
}
