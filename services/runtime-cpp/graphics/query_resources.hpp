#pragma once

#include "limits.hpp"

namespace telar::runtime {

class MediaBudget;
struct MediaUsage;

struct GraphicsQueryResources {
  GraphicsQueryResources() = default;
  GraphicsQueryResources(GraphicsLimits values) noexcept : limits(values) {}
  GraphicsQueryResources(GraphicsLimits values, MediaBudget &shared, MediaUsage *pane_usage = nullptr) noexcept : limits(values), budget(&shared), usage(pane_usage) {}

  GraphicsLimits limits{};
  // Borrowed from RuntimeModel, which outlives all pane controllers/workers.
  // Standalone terminals use a local budget with the same configured limits.
  MediaBudget *budget = nullptr;
  // Owned by PaneMedia; Terminal is destroyed before that shared owner.
  MediaUsage *usage = nullptr;
};

}
