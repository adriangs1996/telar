#pragma once

#include "line.hpp"

namespace telar::runtime::diagnostics {

struct MediaQueue {
  std::uint64_t events = 0;
  std::uint64_t bytes = 0;
  std::uint64_t event_high_water = 0;
  std::uint64_t byte_high_water = 0;
  std::uint64_t dropped_events = 0;
  std::uint64_t dropped_bytes = 0;
  std::uint64_t held_reads = 0;

  void observe(std::size_t event_count, std::size_t byte_count) noexcept {
    events = event_count;
    bytes = byte_count;
    event_high_water = std::max(event_high_water, events);
    byte_high_water = std::max(byte_high_water, bytes);
  }

  void merge(const MediaQueue &other) noexcept {
    accumulate(events, other.events);
    accumulate(bytes, other.bytes);
    accumulate(event_high_water, other.event_high_water);
    accumulate(byte_high_water, other.byte_high_water);
    accumulate(dropped_events, other.dropped_events);
    accumulate(dropped_bytes, other.dropped_bytes);
    accumulate(held_reads, other.held_reads);
  }

  void write(Line &line) const {
    line.field("media_queue_events", events);
    line.field("media_queue_bytes", bytes);
    line.field("media_queue_event_high_water", event_high_water);
    line.field("media_queue_byte_high_water", byte_high_water);
    line.field("media_dropped_events", dropped_events);
    line.field("media_dropped_bytes", dropped_bytes);
    line.field("media_held_reads", held_reads);
  }
};

}
