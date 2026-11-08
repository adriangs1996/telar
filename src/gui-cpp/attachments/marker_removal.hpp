#pragma once

#include "attachments/marker_screen.hpp"
#include "attachments/numeric_markers.hpp"
#include "attachments/path_markers.hpp"
#include "attachments/types.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <cstdint>
#include <optional>

namespace telar::gui {

enum class AttachmentMarkerDeletion : std::uint8_t { backward, forward };
enum class AttachmentMarkerDirection : std::uint8_t { left, right };
enum class AttachmentMarkerReach : std::uint8_t { navigation = 1, path_cells = 2, keys = 3 };

struct AttachmentMarkerRemoval {
  AttachmentMarkerDirection direction = AttachmentMarkerDirection::left;
  std::uint16_t steps = 0;
  AttachmentMarkerDeletion deletion = AttachmentMarkerDeletion::backward;
  std::uint16_t deletions = 1;

  [[nodiscard]] std::uint32_t keyCount() const noexcept {
    return (static_cast<std::uint32_t>(steps) * 2) + deletions;
  }
};

struct AttachmentMarkerPlan {
  std::optional<AttachmentMarkerRemoval> removal;
  std::optional<AttachmentMarkerReach> limit;
  std::optional<std::uint32_t> requested;
};

class AttachmentMarkerPlanning {
public:
  [[nodiscard]] static AttachmentMarkerPlan placeholder(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
    if (!screen.cursor.visible) {
      return {};
    }

    const auto marker = NumericAttachmentMarkers::closest(screen, number);
    if (!marker) {
      return {};
    }

    std::optional<AttachmentMarkerRemoval> removal;
    if (screen.cursor.y == marker->end.y && screen.cursor.x >= marker->end.x) {
      const auto steps = NumericAttachmentMarkers::steps(screen, static_cast<std::uint16_t>(marker->end.y), marker->end.x, screen.cursor.x);
      if (steps) {
        removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::left, .steps = *steps, .deletion = AttachmentMarkerDeletion::backward};
      }
    } else if (screen.cursor.y == marker->start.y && screen.cursor.x <= marker->start.x) {
      const auto steps = NumericAttachmentMarkers::steps(screen, static_cast<std::uint16_t>(marker->start.y), screen.cursor.x, marker->start.x);
      if (steps) {
        removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::right, .steps = *steps, .deletion = AttachmentMarkerDeletion::forward};
      }
    }

    if (removal && removal->steps > AttachmentLimits::maximum_marker_navigation_steps) {
      return {.removal = std::nullopt, .limit = AttachmentMarkerReach::navigation, .requested = removal->steps};
    }

    return {.removal = removal, .limit = std::nullopt, .requested = std::nullopt};
  }

  [[nodiscard]] static AttachmentMarkerPlan path(AttachmentMarkerScreen screen, const AttachmentPathUuid &uuid) noexcept {
    const auto marker = PathAttachmentMarkers::find(screen, uuid);
    if (!marker) {
      return {};
    }

    if (!marker->cells) {
      return {.removal = std::nullopt, .limit = AttachmentMarkerReach::path_cells, .requested = std::nullopt};
    }

    if (const auto cursor = PathAttachmentMarkers::cursorOnRow(screen, static_cast<std::uint16_t>(marker->end.y)); cursor && *cursor >= marker->end.x) {
      const auto steps = plainSteps(screen, static_cast<std::uint16_t>(marker->end.y), marker->end.x, *cursor);
      if (steps) {
        return {.removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::left, .steps = *steps, .deletion = AttachmentMarkerDeletion::backward, .deletions = *marker->cells}, .limit = std::nullopt, .requested = std::nullopt};
      }
    }

    if (const auto cursor = PathAttachmentMarkers::cursorOnRow(screen, static_cast<std::uint16_t>(marker->start.y)); cursor && *cursor <= marker->start.x) {
      const auto steps = plainSteps(screen, static_cast<std::uint16_t>(marker->start.y), *cursor, marker->start.x);
      if (steps) {
        return {.removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::right, .steps = *steps, .deletion = AttachmentMarkerDeletion::forward, .deletions = *marker->cells}, .limit = std::nullopt, .requested = std::nullopt};
      }
    }

    return {};
  }

private:
  [[nodiscard]] static std::optional<std::uint16_t> plainSteps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept {
    if (first > last || last > screen.columns || row >= screen.rows) {
      return std::nullopt;
    }

    std::uint16_t count = 0;
    for (auto column = first; column < last; ++column) {
      const auto *const value = screen.cell({.x = column, .y = row});
      count = static_cast<std::uint16_t>(count + (value != nullptr && value->width != CellWidth::continuation ? 1 : 0));
    }

    return count;
  }
};

}
