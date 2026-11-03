#pragma once

#include "telar_config/agents/evidence.hpp"

namespace telar::runtime {

enum class ObservationKind {
  input,
  output,
  resize,
  shell_exit,
  session_end
};

struct ObservationEvent {
  ObservationKind kind = ObservationKind::output;
  ObservationTime time;
  std::uint32_t offset = 0;
  std::uint32_t length = 0;
  std::optional<bool> shell_foreground = std::nullopt;
  TerminalSize size{};
  int exit_code = 0;
};

struct ObservationBatch {
  void clear() noexcept {
    byte_count = 0;
    event_count = 0;
    reset_before = false;
  }

  std::span<const Byte> bytesOf(const ObservationEvent &event) const noexcept {
    return std::span{bytes}.subspan(event.offset, event.length);
  }

  static constexpr std::size_t byte_capacity = 128 * 1024;
  static constexpr std::size_t event_capacity = 512;
  std::array<Byte, byte_capacity> bytes;
  std::array<ObservationEvent, event_capacity> events;
  std::size_t byte_count = 0;
  std::size_t event_count = 0;
  bool reset_before = false;
};

}
