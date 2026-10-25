#pragma once

#include "line.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime::diagnostics {

struct GraphicsCounters {
  std::uint64_t messages = 0;
  std::uint64_t bytes = 0;
  std::uint64_t images = 0;
  std::uint64_t placements = 0;
  std::uint64_t transfers_staged = 0;
  std::uint64_t transfers_adopted = 0;
  std::uint64_t stage_blocked = 0;
  std::uint64_t stage_deferred = 0;

  template <typename Message>
  void record(const Message &message) {
    accumulate(messages);
    accumulate(bytes, Codec::encodedSize(message));
    if constexpr (std::same_as<Message, GraphicsImage> || std::same_as<Message, GraphicsSharedImage>) {
      accumulate(images);
    } else if constexpr (std::same_as<Message, GraphicsPlacementMessage>) {
      accumulate(placements);
    }
  }

  void write(Line &line) const {
    line.field("graphics_messages", messages);
    line.field("graphics_bytes", bytes);
    line.field("graphics_images_sent", images);
    line.field("graphics_placements_sent", placements);
    line.field("graphics_transfers_staged", transfers_staged);
    line.field("graphics_transfers_adopted", transfers_adopted);
    line.field("graphics_stage_blocked", stage_blocked);
    line.field("graphics_stage_deferred", stage_deferred);
    line.timing("graphics_freeze_avg_us", "graphics_freeze_max_us", Timing{});
  }
};

}
