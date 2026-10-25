#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstring>
#include <variant>

namespace telar::runtime {

class MediaBatch {
public:
  static constexpr std::size_t byte_capacity = 64 * 1024;
  static constexpr std::size_t event_capacity = 64;

  struct Output {
    std::size_t offset;
    std::size_t length;
  };

  using Event = std::variant<Output, TerminalSize>;

  bool append(std::span<const Byte> bytes) noexcept {
    if (bytes.size() > byte_capacity - byte_count_) {
      return false;
    }

    auto *previous = event_count_ == 0 ? nullptr : std::get_if<Output>(&events_[event_count_ - 1]);
    if (previous == nullptr && event_count_ == event_capacity) {
      return false;
    }

    if (!bytes.empty()) {
      std::memcpy(bytes_.data() + byte_count_, bytes.data(), bytes.size());
    }
    if (previous != nullptr) {
      previous->length += bytes.size();
    } else {
      events_[event_count_++] = Output{byte_count_, bytes.size()};
    }
    byte_count_ += bytes.size();
    return true;
  }

  bool resize(TerminalSize size) noexcept {
    if (event_count_ != 0 && std::holds_alternative<TerminalSize>(events_[event_count_ - 1])) {
      events_[event_count_ - 1] = size;
      return true;
    }
    if (event_count_ == event_capacity) {
      return false;
    }

    events_[event_count_++] = size;
    return true;
  }

  void clear() noexcept {
    byte_count_ = 0;
    event_count_ = 0;
    reset_before = false;
    kitty = false;
  }

  std::span<const Event> events() const noexcept {
    return std::span{events_}.first(event_count_);
  }

  std::span<const Byte> bytes(Output output) const noexcept {
    return std::span{bytes_}.subspan(output.offset, output.length);
  }

  std::size_t byteCount() const noexcept {
    return byte_count_;
  }

  bool hasReadCapacity(std::size_t bytes) const noexcept {
    constexpr std::size_t reserved_events = 2;
    return bytes <= byte_capacity - byte_count_ && event_count_ + reserved_events <= event_capacity;
  }

  bool reset_before = false;
  bool kitty = false;

private:
  std::array<Byte, byte_capacity> bytes_;
  std::array<Event, event_capacity> events_;
  std::size_t byte_count_ = 0;
  std::size_t event_count_ = 0;
};

}
