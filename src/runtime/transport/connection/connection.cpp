module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.transport.connection;

import telar.base.ds;

namespace telar::runtime {

  ClientHandshake::ClientHandshake(FileDescriptor descriptor, bool capacity_refused)
      : descriptor_(std::move(descriptor)),
        capacity_refused_(capacity_refused) {}

  void ClientHandshake::read() {
    for (unsigned attempt = 0; attempt < 2 && (stage_ == Stage::prefix || stage_ == Stage::hello); ++attempt) {
      const auto remaining = expected_bytes_ - used_bytes_;
      const auto count = ::read(descriptor_.get(), bytes_.dataMut() + used_bytes_, remaining);
      if (count < 0 && socketWouldBlock(sys::lastError())) {
        return;
      }

      if (count <= 0) {
        throw SystemError{"read client handshake"};
      }

      used_bytes_ += static_cast<std::size_t>(count);
      if (used_bytes_ != expected_bytes_) {
        return;
      }

      if (stage_ == Stage::prefix) {
        std::span<const Byte> prefix{bytes_.data(), frame_prefix_size};
        if (u32::decode(prefix) != HandshakeSchema<ClientHello>::payload_size) {
          throw EncodingError{"Invalid client hello size"};
        }

        expected_bytes_ += HandshakeSchema<ClientHello>::payload_size;
        stage_ = Stage::hello;
      } else {
        negotiate();
      }
    }
  }

  void ClientHandshake::write() {
    if (stage_ != Stage::reply) {
      return;
    }

    const auto count = ::write(descriptor_.get(), bytes_.data() + used_bytes_, expected_bytes_ - used_bytes_);
    if (count < 0 && socketWouldBlock(sys::lastError())) {
      return;
    }

    if (count <= 0) {
      throw SystemError{"write client handshake"};
    }

    used_bytes_ += static_cast<std::size_t>(count);
    if (used_bytes_ == expected_bytes_) {
      stage_ = accepted_ ? Stage::accepted : Stage::rejected;
    }
  }

  int ClientHandshake::descriptor() const noexcept {
    return descriptor_.get();
  }

  FileDescriptor ClientHandshake::takeDescriptor() noexcept {
    return std::move(descriptor_);
  }

  ClientHandshake::Stage ClientHandshake::stage() const noexcept {
    return stage_;
  }

  bool ClientHandshake::reservesClient() const noexcept {
    return !capacity_refused_;
  }

  bool ClientHandshake::expired(std::chrono::steady_clock::time_point now) const noexcept {
    return now - started_at_ >= std::chrono::seconds{2};
  }

  void ClientHandshake::negotiate() {
    const auto hello = HandshakeCodec::decode<ClientHello>(std::span<const Byte>{bytes_}.subspan(frame_prefix_size, HandshakeSchema<ClientHello>::payload_size));

    accepted_ = !capacity_refused_ && hello.schema == handshake::schema_id;
    if (accepted_) {
      reply(ServerAccept{.schema = handshake::schema_id});
    } else {
      reply(ServerReject{.reason = capacity_refused_ ? HandshakeRejectReason::client_limit_reached : HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id});
    }
  }

  template <typename Message>
  void ClientHandshake::reply(const Message& message) {
    const auto payload = HandshakeCodec::encode(message);
    std::span<Byte> output = bytes_.viewMut();

    u32::encode(payload.size(), output);
    std::copy(payload.begin(), payload.end(), output.begin());
    used_bytes_ = 0;
    expected_bytes_ = frame_prefix_size + payload.size();
    stage_ = Stage::reply;
  }

  template <Allocator Memory>
  DeferredResponses<Memory>::DeferredResponses(Memory& memory)
      : entries_(memory) {}

  template <Allocator Memory>
  void DeferredResponses<Memory>::append(std::size_t offset, const DeferredResponse& response) {
    entries_.push(Entry{offset, response});
  }

  template <Allocator Memory>
  bool DeferredResponses<Memory>::precedes(std::size_t offset) const noexcept {
    return !entries_.empty() && entries_.front().offset <= offset;
  }

  template <Allocator Memory>
  std::size_t DeferredResponses<Memory>::offset() const noexcept {
    return entries_.front().offset;
  }

  template <Allocator Memory>
  const DeferredResponse& DeferredResponses<Memory>::response() const noexcept {
    return entries_.front().response;
  }

  template <Allocator Memory>
  bool DeferredResponses<Memory>::empty() const noexcept {
    return entries_.empty();
  }

  template <Allocator Memory>
  void DeferredResponses<Memory>::clear() noexcept {
    entries_.clear();
  }

  template <Allocator Memory>
  void DeferredResponses<Memory>::resolved(std::size_t size) noexcept {
    static_cast<void>(entries_.remove(0));
    for (auto& entry : entries_.viewMut()) {
      entry.offset += size;
    }
  }

  template <Allocator Memory>
  void DeferredResponses<Memory>::eraseBytes(std::size_t offset, std::size_t count) noexcept {
    for (auto& entry : entries_.viewMut()) {
      if (entry.offset > offset) {
        entry.offset -= std::min(count, entry.offset - offset);
      }
    }
  }

  template class DeferredResponses<SystemAllocator>;
  template class DeferredResponses<Memory>;
  template class DeferredResponses<ConcurrentMemory>;
  template class DeferredResponses<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;
  template class DeferredResponses<BudgetAllocator<SystemAllocator>>;

  const char* ResponseQueueFull::what() const noexcept {
    return "Client response queue is full";
  }

  template <Allocator Memory>
  OutgoingFrames<Memory>::OutgoingFrames(Memory& memory)
      : bytes_(memory, byte_limit),
        deferred_(memory) {}

  template <Allocator Memory>
  void OutgoingFrames<Memory>::reserve(std::size_t capacity) {
    bytes_.reserve(capacity);
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::appendPayload(std::span<const Byte> payload) {
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

  template <Allocator Memory>
  void OutgoingFrames<Memory>::consume(std::size_t count) noexcept {
    TELAR_ASSERT(count <= prepared_size_);
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

  template <Allocator Memory>
  void OutgoingFrames<Memory>::clear() noexcept {
    bytes_.clear();
    deferred_.clear();
    lane_counts_.fill(0);
    pending_lanes_ = 0;
    response_depth_ = 0;
    active_offset_ = 0;
    active_remaining_ = 0;
    prepared_size_ = 0;
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::recordDrop() noexcept {
    ++dropped_;
  }

  template <Allocator Memory>
  bool OutgoingFrames<Memory>::active() const noexcept {
    return active_remaining_ != 0;
  }

  template <Allocator Memory>
  DeliveryLane OutgoingFrames<Memory>::nextLane() const noexcept {
    return pending_lanes_ == 0 ? DeliveryLane::count : static_cast<DeliveryLane>(std::countr_zero(pending_lanes_));
  }

  template <Allocator Memory>
  bool OutgoingFrames<Memory>::empty() const noexcept {
    return bytes_.empty() && deferred_.empty();
  }

  template <Allocator Memory>
  std::size_t OutgoingFrames<Memory>::size() const noexcept {
    return bytes_.size();
  }

  template <Allocator Memory>
  std::size_t OutgoingFrames<Memory>::responseDepth() const noexcept {
    return response_depth_;
  }

  template <Allocator Memory>
  std::size_t OutgoingFrames<Memory>::responseHighWater() const noexcept {
    return high_water_;
  }

  template <Allocator Memory>
  std::uint64_t OutgoingFrames<Memory>::dropped() const noexcept {
    return dropped_;
  }

  template <Allocator Memory>
  OutgoingFrames<Memory>::Frame OutgoingFrames<Memory>::inspect(std::size_t offset) const noexcept {
    auto payload = bytes_.readable().subspan(offset);
    const auto size = u32::decode(payload);

    return {frame_prefix_size + size, deliveryLane(static_cast<ServerTag>(payload.front()))};
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::requireCapacity(DeliveryLane lane) const {
    if (responseLane(lane) && response_depth_ == response_capacity) {
      throw ResponseQueueFull{};
    }
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::inserted(DeliveryLane lane) noexcept {
    const auto index = static_cast<std::size_t>(lane);

    ++lane_counts_.atMut(index);
    pending_lanes_ |= std::uint32_t{1} << index;
    if (responseLane(lane)) {
      ++response_depth_;
      high_water_ = std::max(high_water_, response_depth_);
    }
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::start(std::size_t offset, Frame frame) noexcept {
    const auto index = static_cast<std::size_t>(frame.lane);
    if (--lane_counts_.atMut(index) == 0) {
      pending_lanes_ &= ~(std::uint32_t{1} << index);
    }

    if (responseLane(frame.lane)) {
      --response_depth_;
    }

    active_offset_ = offset;
    active_remaining_ = frame.size;
  }

  template class OutgoingFrames<SystemAllocator>;
  template class OutgoingFrames<Memory>;
  template class OutgoingFrames<ConcurrentMemory>;
  template class OutgoingFrames<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;
  template class OutgoingFrames<BudgetAllocator<SystemAllocator>>;

  template <Allocator Memory>
  Connection<Memory>::Connection(Memory& memory, FileDescriptor descriptor)
      : descriptor_(std::move(descriptor)),
        input_(memory, input_limit),
        output_(memory),
        decode_bytes_(memory) {
    input_.reserve(read_batch_size);
    output_.reserve(read_batch_size);
    decode_bytes_.resize(decode_capacity);
  }

  template <Allocator Memory>
  bool Connection<Memory>::read() {
    ds::Array<Byte, read_batch_size> buffer;
    const auto count = ::read(descriptor_.get(), buffer.dataMut(), buffer.size());
    if (count > 0) {
      input_.append(std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count)));
      return true;
    }

    return count < 0 && socketWouldBlock(sys::lastError());
  }

  template <Allocator Memory>
  Connection<Memory>::Frames::Frames(Memory& memory)
      : input(memory, input_limit),
        decode(memory) {}

  template <Allocator Memory>
  void Connection<Memory>::exchange(Frames& frames) noexcept {
    input_.swap(frames.input);
    std::swap(decode_bytes_, frames.decode);
  }

  template <Allocator Memory>
  void Connection<Memory>::sendPayload(std::span<const Byte> payload) {
    output_.appendPayload(payload);
  }

  template <Allocator Memory>
  bool Connection<Memory>::trySendPayload(std::span<const Byte> payload) {
    try {
      output_.appendPayload(payload);
      return true;
    } catch (const ResponseQueueFull&) {
    } catch (const std::bad_alloc&) {
    }

    return false;
  }

  template <Allocator Memory>
  void Connection<Memory>::closeImmediately() noexcept {
    closing = true;
    read_paused = true;
    output_.clear();
  }

  template <Allocator Memory>
  std::size_t Connection<Memory>::responseDepth() const noexcept {
    return output_.responseDepth();
  }

  template <Allocator Memory>
  std::size_t Connection<Memory>::responseHighWater() const noexcept {
    return output_.responseHighWater();
  }

  template <Allocator Memory>
  std::uint64_t Connection<Memory>::droppedResponses() const noexcept {
    return output_.dropped();
  }

  template <Allocator Memory>
  bool Connection<Memory>::writing() const noexcept {
    return output_.active();
  }

  template <Allocator Memory>
  DeliveryLane Connection<Memory>::nextLane() const noexcept {
    return output_.nextLane();
  }

  template <Allocator Memory>
  int Connection<Memory>::descriptor() const noexcept {
    return descriptor_.get();
  }

  template <Allocator Memory>
  bool Connection<Memory>::hasOutput() const noexcept {
    return !output_.empty();
  }

  template <Allocator Memory>
  std::size_t Connection<Memory>::queuedBytes() const noexcept {
    return output_.size();
  }

  template class Connection<SystemAllocator>;
  template class Connection<Memory>;
  template class Connection<ConcurrentMemory>;
  template class Connection<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
