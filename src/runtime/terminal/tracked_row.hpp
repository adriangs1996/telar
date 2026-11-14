#pragma once

#include "ghostty_handle.hpp"
#include "telar_ghostty/vt.hpp"
#include <cstdint>
#include <optional>
#include <utility>

namespace telar::runtime {

  // A row of a terminal's grid that the terminal follows through reflow until the scrollback
  // drops it. Empty when ghostty could not track the row.
  class TrackedRow {
  public:
    TrackedRow() = default;

    // Follows the active area's row `row`.
    static TrackedRow active(GhosttyTerminal terminal, std::uint32_t row) noexcept {
      TrackedRow tracked;
      const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {0, row}}};
      if (ghostty_terminal_grid_ref_track(terminal, point, &tracked.ref_) != GHOSTTY_SUCCESS) {
        tracked.ref_ = nullptr;
      }

      return tracked;
    }

    TrackedRow(const TrackedRow&) = delete;
    TrackedRow& operator=(const TrackedRow&) = delete;

    TrackedRow(TrackedRow&& other) noexcept
        : ref_(std::exchange(other.ref_, nullptr)) {}

    TrackedRow& operator=(TrackedRow&& other) noexcept {
      if (this != &other) {
        release();
        ref_ = std::exchange(other.ref_, nullptr);
      }

      return *this;
    }

    ~TrackedRow() {
      release();
    }

    explicit operator bool() const noexcept {
      return ref_ != nullptr;
    }

    // The row from the top of the scrollback; nothing once the scrollback dropped it.
    [[nodiscard]] std::optional<std::uint32_t> row(GhosttyTerminal terminal) const noexcept {
      auto reference = ghosttySized<GhosttyGridRef>();
      if (ref_ == nullptr || ghostty_tracked_grid_ref_snapshot(ref_, &reference) != GHOSTTY_SUCCESS) {
        return std::nullopt;
      }

      GhosttyPointCoordinate coordinate{};
      if (ghostty_terminal_point_from_grid_ref(terminal, &reference, GHOSTTY_POINT_TAG_SCREEN, &coordinate) != GHOSTTY_SUCCESS) {
        return std::nullopt;
      }

      return coordinate.y;
    }

  private:
    void release() noexcept {
      if (ref_ != nullptr) {
        ghostty_tracked_grid_ref_free(ref_);
        ref_ = nullptr;
      }
    }

    GhosttyTrackedGridRef ref_ = nullptr;
  };

}
