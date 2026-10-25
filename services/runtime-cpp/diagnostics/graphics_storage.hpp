#pragma once

#include "line.hpp"

namespace telar::runtime::diagnostics {

struct GraphicsStorageSnapshot {
  std::uint64_t images = 0;
  std::uint64_t placements = 0;
  std::uint64_t resident_bytes = 0;
  std::uint64_t loading_bytes = 0;
  std::uint64_t prepared_bytes = 0;
  std::uint64_t staged_bytes = 0;
  std::uint64_t transfer_bytes = 0;
  std::uint64_t busy_panes = 0;

  void merge(const GraphicsStorageSnapshot &other) noexcept {
    accumulate(images, other.images);
    accumulate(placements, other.placements);
    accumulate(resident_bytes, other.resident_bytes);
    accumulate(loading_bytes, other.loading_bytes);
    accumulate(prepared_bytes, other.prepared_bytes);
    accumulate(staged_bytes, other.staged_bytes);
    accumulate(transfer_bytes, other.transfer_bytes);
    accumulate(busy_panes, other.busy_panes);
  }

  void write(Line &line) const {
    line.field("graphics_images", images);
    line.field("graphics_placements", placements);
    auto resident = resident_bytes;
    accumulate(resident, transfer_bytes);
    line.field("graphics_resident_bytes", resident);
    line.field("graphics_loading_bytes", loading_bytes);
    line.field("graphics_prepared_bytes", prepared_bytes);
    line.field("graphics_staged_bytes", staged_bytes);
    line.field("graphics_transfer_bytes", transfer_bytes);
    line.field("graphics_busy_panes", busy_panes);
  }
};

}
