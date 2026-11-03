#pragma once

#include "deferred_responses.hpp"
#include "delivery_lane.hpp"
#include "telar_base/memory/byte_queue.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <bit>
#include <exception>

namespace telar::runtime {

class ResponseQueueFull : public std::exception {
public:
  const char *what() const noexcept override {
    return "Client response queue is full";
  }
};

template <Allocator Memory>
class OutgoingFrames {
public:
  static constexpr std::size_t response_capacity = 128;

  explicit OutgoingFrames(Memory &memory) : bytes_(memory, byte_limit), deferred_(memory) {}

  void reserve(std::size_t capacity) {
    bytes_.reserve(capacity);
  }

  template <typename Message>
  void append(const Message &message) {
    static_assert(MessageSchema<Message>::direction == Direction::server);
    const auto lane = deliveryLane(MessageSchema<Message>::tag);
    requireCapacity(lane);
    const auto size = Codec::encodedSize(message);
    const auto previous_size = bytes_.size();

    try {
      auto frame = bytes_.appendUninitialized(frame_prefix_size + size);
      u32::encode(static_cast<std::uint32_t>(size), frame);
      Codec::encode(message, frame);
    } catch (...) {
      bytes_.truncate(previous_size);
      throw;
    }

    inserted(lane);
  }

  void appendPayload(std::span<const Byte> payload) {
    if (payload.empty() || payload.size() > max_payload_size) {
      throw EncodingError{"Invalid outgoing payload size"};
    }

    const auto lane = deliveryLane(static_cast<ServerTag>(payload.front()));
    requireCapacity(lane);
    auto frame = bytes_.appendUninitialized(frame_prefix_size + payload.size());
    u32::encode(static_cast<std::uint32_t>(payload.size()), frame);
    std::copy(payload.begin(), payload.end(), frame.begin());
    inserted(lane);
  }

  // Publication may append and relocate storage, but must not drive the writer.
  // Re-encode by offset after publication so the reserved confirmation survives.
  template <typename Message, typename Publish>
  void appendConfirmation(Message message, Publish &&publish) {
    static_assert(MessageSchema<Message>::fixed_size);
    const auto offset = bytes_.size() + frame_prefix_size;
    append(message);
    publish(message);
    std::array<Byte, MessageSchema<Message>::payload_size> payload;
    Codec::encode(message, payload);
    bytes_.overwrite(offset, payload);
  }

  template <DeferredRequest Request>
  void defer(const Request &request) {
    requireCapacity(DeliveryLane::management);
    deferred_.append(bytes_.size(), request);
    inserted(DeliveryLane::management);
  }

  template <DeferredResponseEncoder Encoder = RejectDeferredResponse>
  std::span<const Byte> prepare(std::size_t limit, Encoder &&encode = {}) {
    if (empty() || limit == 0) {
      return {};
    }

    if (active_remaining_ != 0) {
      prepared_size_ = std::min(active_remaining_, limit);
      return bytes_.readable().subspan(active_offset_, prepared_size_);
    }

    const auto lane = static_cast<DeliveryLane>(std::countr_zero(pending_lanes_));
    auto offset = std::size_t{0};
    while (offset < bytes_.size() && inspect(offset).lane != lane) {
      offset += inspect(offset).size;
    }

    if (lane == DeliveryLane::management && deferred_.precedes(offset)) {
      offset = deferred_.offset();
      resolve(encode);
    }

    const auto frame = inspect(offset);
    start(offset, frame);
    auto end = offset + frame.size;
    while (end < bytes_.size() && end - offset < limit) {
      if (lane == DeliveryLane::management && deferred_.precedes(end)) {
        break;
      }

      const auto next = inspect(end);
      if (next.lane != lane) {
        break;
      }

      end += next.size;
    }

    prepared_size_ = std::min(end - offset, limit);
    return bytes_.readable().subspan(offset, prepared_size_);
  }

  void consume(std::size_t count) noexcept {
    assert(count <= prepared_size_);
    auto remaining = count;
    const auto first_offset = active_offset_;
    auto offset = first_offset;
    while (remaining >= active_remaining_ && active_remaining_ != 0) {
      remaining -= active_remaining_;
      offset += active_remaining_;
      active_remaining_ = 0;
      if (remaining != 0) {
        start(offset, inspect(offset));
      }
    }

    active_remaining_ -= remaining;
    bytes_.erase(first_offset, count);
    deferred_.eraseBytes(first_offset, count);
    active_offset_ = first_offset;
    prepared_size_ = 0;
  }

  void clear() noexcept {
    bytes_.clear();
    deferred_.clear();
    lane_counts_.fill(0);
    pending_lanes_ = 0;
    response_depth_ = 0;
    active_offset_ = 0;
    active_remaining_ = 0;
    prepared_size_ = 0;
  }

  void recordDrop() noexcept { ++dropped_; }
  bool active() const noexcept { return active_remaining_ != 0; }
  DeliveryLane nextLane() const noexcept {
    return pending_lanes_ == 0 ? DeliveryLane::count : static_cast<DeliveryLane>(std::countr_zero(pending_lanes_));
  }

  bool empty() const noexcept { return bytes_.empty() && deferred_.empty(); }
  std::size_t size() const noexcept { return bytes_.size(); }
  std::size_t responseDepth() const noexcept { return response_depth_; }
  std::size_t responseHighWater() const noexcept { return high_water_; }
  std::uint64_t dropped() const noexcept { return dropped_; }

private:
  template <DeferredResponseEncoder Encoder>
  void resolve(Encoder &encode) {
    const auto offset = deferred_.offset();
    std::size_t resolved_size = 0;
    encode(deferred_.response(), [&](const auto &message) {
      using Message = std::remove_cvref_t<decltype(message)>;
      static_assert(deliveryLane(MessageSchema<Message>::tag) == DeliveryLane::management);
      if (resolved_size != 0) {
        throw std::logic_error{"A deferred response must produce exactly one frame"};
      }

      const auto size = Codec::encodedSize(message);
      auto frame = bytes_.insertUninitialized(offset, frame_prefix_size + size);
      try {
        u32::encode(static_cast<std::uint32_t>(size), frame);
        Codec::encode(message, frame);
      } catch (...) {
        bytes_.erase(offset, frame_prefix_size + size);
        throw;
      }
      resolved_size = frame_prefix_size + size;
    });

    if (resolved_size == 0) {
      throw std::logic_error{"A deferred response must produce exactly one frame"};
    }
    deferred_.resolved(resolved_size);
  }

  struct Frame {
    std::size_t size;
    DeliveryLane lane;
  };

  Frame inspect(std::size_t offset) const noexcept {
    auto payload = bytes_.readable().subspan(offset);
    const auto size = u32::decode(payload);
    return {frame_prefix_size + size, deliveryLane(static_cast<ServerTag>(payload.front()))};
  }

  void requireCapacity(DeliveryLane lane) const {
    if (responseLane(lane) && response_depth_ == response_capacity) {
      throw ResponseQueueFull{};
    }
  }

  void inserted(DeliveryLane lane) noexcept {
    const auto index = static_cast<std::size_t>(lane);
    ++lane_counts_[index];
    pending_lanes_ |= std::uint32_t{1} << index;
    if (responseLane(lane)) {
      ++response_depth_;
      high_water_ = std::max(high_water_, response_depth_);
    }
  }

  void start(std::size_t offset, Frame frame) noexcept {
    const auto index = static_cast<std::size_t>(frame.lane);
    if (--lane_counts_[index] == 0) {
      pending_lanes_ &= ~(std::uint32_t{1} << index);
    }

    if (responseLane(frame.lane)) {
      --response_depth_;
    }

    active_offset_ = offset;
    active_remaining_ = frame.size;
  }

  static constexpr std::size_t byte_limit = 2 * (max_payload_size + frame_prefix_size);
  ByteQueue<Memory> bytes_;
  DeferredResponses<Memory> deferred_;
  std::array<std::size_t, static_cast<std::size_t>(DeliveryLane::count)> lane_counts_{};
  std::uint32_t pending_lanes_ = 0;
  std::size_t response_depth_ = 0;
  std::size_t high_water_ = 0;
  std::uint64_t dropped_ = 0;
  std::size_t active_offset_ = 0;
  std::size_t active_remaining_ = 0;
  std::size_t prepared_size_ = 0;
};

}
