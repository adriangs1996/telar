#pragma once

#include "../platform/stream_read_buffer.hpp"
#include "protocol.hpp"
#include "telar_base/memory/sensitive_allocation.hpp"
#include "telar_platform/error.hpp"

namespace telar::runtime::plugins {

template <typename Stream>
concept FrameStream = requires(Stream &stream, std::span<Byte> destination, std::span<const Byte> bytes) {
  { stream.read(destination) } noexcept -> std::same_as<StreamResult>;
  { stream.write(bytes, bytes) } -> std::same_as<void>;
};

template <FrameStream Stream>
class FrameChannel {
public:
  explicit FrameChannel(Stream &stream) noexcept : stream_(stream) {}

  template <Allocator Memory>
  std::optional<SensitiveAllocation<Memory>> receive(Memory &memory, std::size_t maximum_bytes) {
    std::array<Byte, Protocol::prefix_bytes> prefix;
    if (!readExact(prefix)) {
      return std::nullopt;
    }

    std::span<const Byte> remaining{prefix};
    const auto length = LittleEndian<std::uint32_t>::decode(remaining);
    if (length == 0 || length > maximum_bytes) {
      throw EncodingError{"Invalid tap frame length"};
    }

    SensitiveAllocation frame{memory, length};
    if (!readExact(frame.bytes())) {
      throw SystemError{"Incomplete tap frame", EPIPE};
    }
    return frame;
  }

  void send(std::span<const Byte> payload) {
    if (payload.empty() || payload.size() > Limits::frame_bytes) {
      throw EncodingError{"Invalid tap frame length"};
    }

    std::array<Byte, Protocol::prefix_bytes> prefix;
    std::span<Byte> remaining{prefix};
    LittleEndian<std::uint32_t>::encode(static_cast<std::uint32_t>(payload.size()), remaining);
    stream_.write(prefix, payload);
  }

private:
  bool readExact(std::span<Byte> destination) {
    while (!destination.empty()) {
      const auto count = readNext(destination);
      if (count == 0) {
        return false;
      }

      destination = destination.subspan(count);
    }
    return true;
  }

  std::size_t readNext(std::span<Byte> destination) {
    if (input_.empty() && destination.size() >= input_capacity) {
      const auto received = stream_.read(destination);
      requireReadable(received.state);
      return received.bytes;
    }

    const auto view = input_.peek([this](std::span<Byte> bytes) noexcept { return stream_.read(bytes); }, destination.size());
    requireReadable(view.state);
    return input_.copyTo(destination);
  }

  static void requireReadable(StreamResult::State state) {
    if (state != StreamResult::State::data && state != StreamResult::State::ended) {
      throw SystemError{"Read tap frame"};
    }
  }

  static constexpr std::size_t input_capacity = 16 * 1024;
  Stream &stream_;
  StreamReadBuffer<input_capacity> input_;
};

template <FrameStream Stream>
FrameChannel(Stream &stream) -> FrameChannel<Stream>;

}
