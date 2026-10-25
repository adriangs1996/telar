#pragma once

#include "socket_stream.hpp"
#include <array>
#include <cstdint>

namespace telar::runtime {

template <std::size_t BufferCapacity = 16 * 1024>
class RelayDirection {
  static_assert(BufferCapacity != 0);

public:
  enum class Observation { received,
                           forwarded };
  static constexpr std::size_t capacity = BufferCapacity;
  struct Progress {
    std::size_t read = 0;
    std::size_t written = 0;

    bool active() const noexcept {
      return read != 0 || written != 0;
    }
  };

  Progress advance(int source, int destination) noexcept {
    SocketStream incoming{source};
    SocketStream outgoing{destination};
    return advance(incoming, outgoing);
  }

  template <ByteStream Source, ByteStream Destination>
  Progress advance(Source &source, Destination &destination) noexcept {
    return advance(source, destination, [](Observation, std::span<const std::uint8_t>) noexcept {});
  }

  template <ByteStream Source, ByteStream Destination, typename Observer>
    requires requires(Observer observe, Observation stage, std::span<const std::uint8_t> bytes) {
      { observe(stage, bytes) } noexcept -> std::same_as<void>;
    }
  Progress advance(Source &source, Destination &destination, Observer observe) noexcept {
    Progress progress;
    if (wantsRead()) {
      const auto received = source.read(bytes_);
      if (received.state == StreamResult::State::data) {
        length_ = received.bytes;
        progress.read = length_;
        read_waiting_ = StreamReadiness::readable;
        observe(Observation::received, std::span{bytes_}.first(length_));
      } else if (received.state == StreamResult::State::blocked) {
        read_waiting_ = received.waiting;
      } else {
        ended_ = true;
      }
    }

    if (wantsWrite()) {
      const auto sent = destination.write(std::span{bytes_}.subspan(offset_, length_ - offset_));
      if (sent.state == StreamResult::State::data) {
        progress.written = sent.bytes;
        offset_ += progress.written;
        write_waiting_ = StreamReadiness::writable;
        if (offset_ == length_) {
          observe(Observation::forwarded, std::span{bytes_}.first(length_));
          offset_ = 0;
          length_ = 0;
        }
      } else if (sent.state == StreamResult::State::blocked) {
        write_waiting_ = sent.waiting;
      } else {
        ended_ = true;
        offset_ = 0;
        length_ = 0;
      }
    }

    if (finished() && !shutdown_) {
      destination.halfClose();
      shutdown_ = true;
    }
    return progress;
  }

  bool wantsRead() const noexcept {
    return !ended_ && length_ == 0;
  }

  bool wantsWrite() const noexcept {
    return length_ != 0;
  }

  bool finished() const noexcept {
    return ended_ && length_ == 0;
  }

  StreamReadiness sourceInterest() const noexcept {
    return wantsRead() ? read_waiting_ : StreamReadiness::none;
  }

  StreamReadiness destinationInterest() const noexcept {
    return wantsWrite() ? write_waiting_ : StreamReadiness::none;
  }

private:
  std::array<std::uint8_t, capacity> bytes_;
  std::size_t offset_ = 0;
  std::size_t length_ = 0;
  StreamReadiness read_waiting_ = StreamReadiness::readable;
  StreamReadiness write_waiting_ = StreamReadiness::writable;
  bool ended_ = false;
  bool shutdown_ = false;
};

}
