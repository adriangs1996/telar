#pragma once

#include "../memory/byte_queue.hpp"
#include "../platform/error.hpp"
#include "../platform/file_descriptor.hpp"
#include "outgoing_frames.hpp"
#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <chrono>

namespace telar::runtime {

template <Allocator Memory>
class Connection {
public:
  explicit Connection(Memory &memory, FileDescriptor descriptor)
      : descriptor_(std::move(descriptor)),
        input_(memory, input_limit),
        output_(memory),
        decode_bytes_(AllocatorRef<Byte, Memory>{memory}) {
    input_.reserve(read_batch_size);
    output_.reserve(read_batch_size);
    decode_bytes_.resize(decode_capacity);
  }

  bool read() {
    std::array<Byte, read_batch_size> buffer;
    const auto count = ::read(descriptor_.get(), buffer.data(), buffer.size());
    if (count > 0) {
      input_.append(std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count)));
      return true;
    }

    return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
  }

  template <typename Visitor>
  bool dispatch(Visitor &&visitor) {
    constexpr unsigned messages_per_batch = 64;

    for (unsigned index = 0; index < messages_per_batch; ++index) {
      if (read_paused) {
        return input_.size() >= frame_prefix_size;
      }

      auto bytes = input_.readable();
      if (bytes.size() < frame_prefix_size) {
        return false;
      }

      const auto length = u32::decode(bytes);
      if (length == 0 || length > max_payload_size) {
        throw EncodingError{"Invalid transport frame size"};
      }

      if (length > bytes.size()) {
        return false;
      }

      DecodeStorage storage{decode_bytes_};
      visitor(bytes.first(length), storage);
      input_.consume(frame_prefix_size + length);
    }

    return input_.size() >= frame_prefix_size;
  }

  template <typename Visitor>
  void replay(std::span<const Byte> payload, Visitor &&visitor) {
    DecodeStorage storage{decode_bytes_};
    visitor(payload, storage);
  }

  template <DeferredResponseEncoder Encoder = RejectDeferredResponse>
  void write(Encoder &&encode = {}) {
    constexpr std::size_t write_batch_size = 256 * 1024;
    const auto bytes = output_.prepare(write_batch_size, std::forward<Encoder>(encode));
    if (bytes.empty()) {
      return;
    }

    const auto count = ::write(descriptor_.get(), bytes.data(), bytes.size());
    if (count > 0) {
      output_.consume(static_cast<std::size_t>(count));
      return;
    }

    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return;
    }

    throw SystemError{"write runtime client"};
  }

  template <typename Message>
  void send(const Message &message) {
    output_.append(message);
  }

  template <DeferredRequest Request>
  void defer(const Request &request) {
    output_.defer(request);
  }

  template <typename Message>
  bool trySend(const Message &message) {
    try {
      output_.append(message);
      return true;
    } catch (const ResponseQueueFull &) {
      output_.recordDrop();
    } catch (const std::bad_alloc &) {
      output_.recordDrop();
    }
    return false;
  }

  template <typename Message, typename Publish>
  void sendConfirmation(Message message, Publish &&publish) {
    output_.appendConfirmation(message, std::forward<Publish>(publish));
  }

  void sendPayload(std::span<const Byte> payload) {
    output_.appendPayload(payload);
  }

  bool trySendPayload(std::span<const Byte> payload) {
    try {
      output_.appendPayload(payload);
      return true;
    } catch (const ResponseQueueFull &) {
    } catch (const std::bad_alloc &) {
    }
    return false;
  }

  void closeImmediately() noexcept {
    closing = true;
    read_paused = true;
    output_.clear();
  }

  std::size_t responseDepth() const noexcept { return output_.responseDepth(); }
  std::size_t responseHighWater() const noexcept { return output_.responseHighWater(); }
  std::uint64_t droppedResponses() const noexcept { return output_.dropped(); }
  bool writing() const noexcept { return output_.active(); }
  DeliveryLane nextLane() const noexcept { return output_.nextLane(); }

  int descriptor() const noexcept {
    return descriptor_.get();
  }

  bool hasOutput() const noexcept {
    return !output_.empty();
  }

  std::size_t queuedBytes() const noexcept {
    return output_.size();
  }

  bool negotiated = false;
  bool closing = false;
  bool buffered_requests = false;
  bool write_interest = false;
  bool read_paused = false;
  bool read_interest = true;

private:
  static constexpr std::size_t read_batch_size = 64 * 1024;
  static constexpr std::size_t decode_capacity = 128 * 1024;
  static constexpr std::size_t input_limit = max_payload_size + read_batch_size + frame_prefix_size;
  FileDescriptor descriptor_;
  ByteQueue<Memory> input_;
  OutgoingFrames<Memory> output_;
  Vector<Byte, Memory> decode_bytes_;
};

}
