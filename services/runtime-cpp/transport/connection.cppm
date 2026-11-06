module;

#include "telar_client/codecs/telar_codec.hpp"
#include <array>
#include <cstddef>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <chrono>


#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <stdexcept>


#include "telar_client/serializers/telar_messages.hpp"


#include <cassert>
#include <cstdint>
#include <cstring>
#include <bit>

export module telar.runtime.transport.connection;

export import telar.client;
export import telar.platform;


export import telar.base.memory;

// Interface: transport/client_handshake.cppm
export {
namespace telar::runtime {

class ClientHandshake {
public:
  enum class Stage {
    prefix,
    hello,
    reply,
    accepted,
    rejected
  };

  inline explicit ClientHandshake(FileDescriptor descriptor, bool capacity_refused)
      : descriptor_(std::move(descriptor)),
        capacity_refused_(capacity_refused) {}

  inline void read() {
    for (unsigned attempt = 0; attempt < 2 && (stage_ == Stage::prefix || stage_ == Stage::hello); ++attempt) {
      const auto remaining = expected_bytes_ - used_bytes_;
      const auto count = ::read(descriptor_.get(), bytes_.data() + used_bytes_, remaining);
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
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

  inline void write() {
    if (stage_ != Stage::reply) {
      return;
    }

    const auto count = ::write(descriptor_.get(), bytes_.data() + used_bytes_, expected_bytes_ - used_bytes_);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
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

  inline int descriptor() const noexcept {
    return descriptor_.get();
  }

  inline FileDescriptor takeDescriptor() noexcept {
    return std::move(descriptor_);
  }

  inline Stage stage() const noexcept {
    return stage_;
  }

  inline bool reservesClient() const noexcept {
    return !capacity_refused_;
  }

  inline bool expired(std::chrono::steady_clock::time_point now) const noexcept {
    return now - started_at_ >= std::chrono::seconds{2};
  }

private:
  inline void negotiate() {
    const auto hello = HandshakeCodec::decode<ClientHello>(std::span<const Byte>{bytes_}.subspan(frame_prefix_size, HandshakeSchema<ClientHello>::payload_size));
    accepted_ = !capacity_refused_ && hello.schema == handshake::schema_id;
    if (accepted_) {
      reply(ServerAccept{.schema = handshake::schema_id});
    } else {
      reply(ServerReject{.reason = capacity_refused_ ? HandshakeRejectReason::client_limit_reached : HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id});
    }
  }

  template <typename Message>
  inline void reply(const Message &message) {
    const auto payload = HandshakeCodec::encode(message);
    std::span<Byte> output = bytes_;
    u32::encode(payload.size(), output);
    std::copy(payload.begin(), payload.end(), output.begin());
    used_bytes_ = 0;
    expected_bytes_ = frame_prefix_size + payload.size();
    stage_ = Stage::reply;
  }

  FileDescriptor descriptor_;
  std::array<Byte, frame_prefix_size + HandshakeCodec::max_message_size> bytes_;
  std::size_t used_bytes_ = 0;
  std::size_t expected_bytes_ = frame_prefix_size;
  std::chrono::steady_clock::time_point started_at_ = std::chrono::steady_clock::now();
  Stage stage_ = Stage::prefix;
  bool capacity_refused_;
  bool accepted_ = false;
};

}
}

// Interface: transport/deferred_responses.cppm
export {
namespace telar::runtime {

template <typename Request>
concept DeferredRequest = std::same_as<Request, ReadPane> || std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot> || std::same_as<Request, QueryLimits>;

using DeferredResponse = std::variant<ReadPane, RequestTabSnapshot, RequestWorkspaceSnapshot, QueryLimits>;

struct RejectDeferredResponse {
  inline void operator()(const DeferredResponse &, auto &&) const {
    throw std::logic_error{"A deferred response requires an encoder"};
  }
};

template <typename Encoder>
concept DeferredResponseEncoder = requires(Encoder &encoder, const DeferredResponse &response) {
  encoder(response, [](const auto &) {});
};

template <Allocator Memory>
class DeferredResponses {
public:
  inline explicit DeferredResponses(Memory &memory) : entries_(AllocatorRef<Entry, Memory>{memory}) {}

  inline void append(std::size_t offset, const DeferredResponse &response) {
    entries_.push_back(Entry{offset, response});
  }

  inline bool precedes(std::size_t offset) const noexcept {
    return !entries_.empty() && entries_.front().offset <= offset;
  }

  inline std::size_t offset() const noexcept { return entries_.front().offset; }
  inline const DeferredResponse &response() const noexcept { return entries_.front().response; }
  inline bool empty() const noexcept { return entries_.empty(); }
  inline void clear() noexcept { entries_.clear(); }

  inline void resolved(std::size_t size) noexcept {
    entries_.erase(entries_.begin());
    for (auto &entry : entries_) {
      entry.offset += size;
    }
  }

  // Offsets mark admission boundaries in the encoded byte queue. Removing a
  // higher-priority frame collapses any boundaries inside that byte range.
  inline void eraseBytes(std::size_t offset, std::size_t count) noexcept {
    for (auto &entry : entries_) {
      if (entry.offset > offset) {
        entry.offset -= std::min(count, entry.offset - offset);
      }
    }
  }

private:
  struct Entry {
    std::size_t offset;
    DeferredResponse response;
  };

  Vector<Entry, Memory> entries_;
};

}
}

// Interface: transport/delivery_lane.cppm
export {
namespace telar::runtime {

enum class DeliveryLane : std::uint8_t {
  stopping,
  management,
  resync,
  clipboard,
  layout,
  proxy,
  cells,
  agents,
  metrics,
  workspaces,
  cwd,
  foreground,
  title,
  progress,
  exit,
  graphics,
  observation,
  count,
};

constexpr DeliveryLane deliveryLane(ServerTag tag) {
  switch (tag) {
  case ServerTag::runtime_stopping:
    return DeliveryLane::stopping;
  case ServerTag::resync_required:
    return DeliveryLane::resync;
  case ServerTag::pane_clipboard:
    return DeliveryLane::clipboard;
  case ServerTag::client_layout_snapshot:
    return DeliveryLane::layout;
  case ServerTag::proxy_status:
    return DeliveryLane::proxy;
  case ServerTag::pane_frame:
    return DeliveryLane::cells;
  case ServerTag::agent_snapshot:
    return DeliveryLane::agents;
  case ServerTag::system_metrics:
    return DeliveryLane::metrics;
  case ServerTag::workspace_list:
    return DeliveryLane::workspaces;
  case ServerTag::pane_cwd:
    return DeliveryLane::cwd;
  case ServerTag::pane_foreground:
    return DeliveryLane::foreground;
  case ServerTag::pane_title:
    return DeliveryLane::title;
  case ServerTag::pane_progress:
    return DeliveryLane::progress;
  case ServerTag::pane_exited:
    return DeliveryLane::exit;
  case ServerTag::history_results:
    return DeliveryLane::observation;
  case ServerTag::graphics_snapshot:
  case ServerTag::graphics_image:
  case ServerTag::graphics_image_chunk:
  case ServerTag::graphics_placement:
  case ServerTag::graphics_delete_image:
  case ServerTag::graphics_delete_placement:
  case ServerTag::graphics_shared_image:
    return DeliveryLane::graphics;
  case ServerTag::pane_opened:
  case ServerTag::request_failed:
  case ServerTag::tab_snapshot:
  case ServerTag::workspace_snapshot:
  case ServerTag::tab_created:
  case ServerTag::tab_renamed:
  case ServerTag::tab_closed:
  case ServerTag::tab_moved:
  case ServerTag::notification:
  case ServerTag::notification_shown:
  case ServerTag::agent_sound:
  case ServerTag::pane_text:
  case ServerTag::request_completed:
  case ServerTag::pane_matches:
  case ServerTag::history_pruned:
  case ServerTag::history_output:
  case ServerTag::history_stats_result:
  case ServerTag::pane_focus_command:
  case ServerTag::pane_focus_result:
  case ServerTag::command_suggestion:
  case ServerTag::client_list:
  case ServerTag::client_command:
  case ServerTag::client_command_result:
  case ServerTag::editor_opened:
  case ServerTag::path_results:
  case ServerTag::worktree_registered:
  case ServerTag::limit_list:
  case ServerTag::execution_reply:
  case ServerTag::clipboard_desktop_request:
  case ServerTag::clipboard_desktop_execute:
  case ServerTag::clipboard_desktop_cancel:
  case ServerTag::runtime_clipboard_chunk:
    return DeliveryLane::management;
  }

  throw EncodingError{"Unknown outgoing message tag"};
}

constexpr bool responseLane(DeliveryLane lane) noexcept {
  return lane == DeliveryLane::management || lane == DeliveryLane::observation;
}

}
}

// Interface: transport/outgoing_frames.cppm
export {
namespace telar::runtime {

class ResponseQueueFull : public std::exception {
public:
  inline const char *what() const noexcept override {
    return "Client response queue is full";
  }
};

template <Allocator Memory>
class OutgoingFrames {
public:
  static constexpr std::size_t response_capacity = 128;

  inline explicit OutgoingFrames(Memory &memory) : bytes_(memory, byte_limit), deferred_(memory) {}

  inline void reserve(std::size_t capacity) {
    bytes_.reserve(capacity);
  }

  template <typename Message>
  inline void append(const Message &message) {
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

  inline void appendPayload(std::span<const Byte> payload) {
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
  inline void appendConfirmation(Message message, Publish &&publish) {
    static_assert(MessageSchema<Message>::fixed_size);
    const auto offset = bytes_.size() + frame_prefix_size;
    append(message);
    publish(message);
    std::array<Byte, MessageSchema<Message>::payload_size> payload;
    Codec::encode(message, payload);
    bytes_.overwrite(offset, payload);
  }

  template <DeferredRequest Request>
  inline void defer(const Request &request) {
    requireCapacity(DeliveryLane::management);
    deferred_.append(bytes_.size(), request);
    inserted(DeliveryLane::management);
  }

  template <DeferredResponseEncoder Encoder = RejectDeferredResponse>
  inline std::span<const Byte> prepare(std::size_t limit, Encoder &&encode = {}) {
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

  inline void consume(std::size_t count) noexcept {
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

  inline void clear() noexcept {
    bytes_.clear();
    deferred_.clear();
    lane_counts_.fill(0);
    pending_lanes_ = 0;
    response_depth_ = 0;
    active_offset_ = 0;
    active_remaining_ = 0;
    prepared_size_ = 0;
  }

  inline void recordDrop() noexcept { ++dropped_; }
  inline bool active() const noexcept { return active_remaining_ != 0; }
  inline DeliveryLane nextLane() const noexcept {
    return pending_lanes_ == 0 ? DeliveryLane::count : static_cast<DeliveryLane>(std::countr_zero(pending_lanes_));
  }

  inline bool empty() const noexcept { return bytes_.empty() && deferred_.empty(); }
  inline std::size_t size() const noexcept { return bytes_.size(); }
  inline std::size_t responseDepth() const noexcept { return response_depth_; }
  inline std::size_t responseHighWater() const noexcept { return high_water_; }
  inline std::uint64_t dropped() const noexcept { return dropped_; }

private:
  template <DeferredResponseEncoder Encoder>
  inline void resolve(Encoder &encode) {
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

  inline Frame inspect(std::size_t offset) const noexcept {
    auto payload = bytes_.readable().subspan(offset);
    const auto size = u32::decode(payload);
    return {frame_prefix_size + size, deliveryLane(static_cast<ServerTag>(payload.front()))};
  }

  inline void requireCapacity(DeliveryLane lane) const {
    if (responseLane(lane) && response_depth_ == response_capacity) {
      throw ResponseQueueFull{};
    }
  }

  inline void inserted(DeliveryLane lane) noexcept {
    const auto index = static_cast<std::size_t>(lane);
    ++lane_counts_[index];
    pending_lanes_ |= std::uint32_t{1} << index;
    if (responseLane(lane)) {
      ++response_depth_;
      high_water_ = std::max(high_water_, response_depth_);
    }
  }

  inline void start(std::size_t offset, Frame frame) noexcept {
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
}

// Interface: transport/connection.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class Connection {
public:
  inline explicit Connection(Memory &memory, FileDescriptor descriptor)
      : descriptor_(std::move(descriptor)),
        input_(memory, input_limit),
        output_(memory),
        decode_bytes_(AllocatorRef<Byte, Memory>{memory}) {
    input_.reserve(read_batch_size);
    output_.reserve(read_batch_size);
    decode_bytes_.resize(decode_capacity);
  }

  inline bool read() {
    std::array<Byte, read_batch_size> buffer;
    const auto count = ::read(descriptor_.get(), buffer.data(), buffer.size());
    if (count > 0) {
      input_.append(std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count)));
      return true;
    }

    return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
  }

  template <typename Visitor>
  inline bool dispatch(Visitor &&visitor) {
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
  inline void replay(std::span<const Byte> payload, Visitor &&visitor) {
    DecodeStorage storage{decode_bytes_};
    visitor(payload, storage);
  }

  template <DeferredResponseEncoder Encoder = RejectDeferredResponse>
  inline void write(Encoder &&encode = {}) {
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
  inline void send(const Message &message) {
    output_.append(message);
  }

  template <DeferredRequest Request>
  inline void defer(const Request &request) {
    output_.defer(request);
  }

  template <typename Message>
  inline bool trySend(const Message &message) {
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
  inline void sendConfirmation(Message message, Publish &&publish) {
    output_.appendConfirmation(message, std::forward<Publish>(publish));
  }

  inline void sendPayload(std::span<const Byte> payload) {
    output_.appendPayload(payload);
  }

  inline bool trySendPayload(std::span<const Byte> payload) {
    try {
      output_.appendPayload(payload);
      return true;
    } catch (const ResponseQueueFull &) {
    } catch (const std::bad_alloc &) {
    }
    return false;
  }

  inline void closeImmediately() noexcept {
    closing = true;
    read_paused = true;
    output_.clear();
  }

  inline std::size_t responseDepth() const noexcept { return output_.responseDepth(); }
  inline std::size_t responseHighWater() const noexcept { return output_.responseHighWater(); }
  inline std::uint64_t droppedResponses() const noexcept { return output_.dropped(); }
  inline bool writing() const noexcept { return output_.active(); }
  inline DeliveryLane nextLane() const noexcept { return output_.nextLane(); }

  inline int descriptor() const noexcept {
    return descriptor_.get();
  }

  inline bool hasOutput() const noexcept {
    return !output_.empty();
  }

  inline std::size_t queuedBytes() const noexcept {
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
}

// Interface: transport/encoded_reply.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class EncodedReply {
public:
  inline explicit EncodedReply(Memory &memory)
      : bytes_(AllocatorRef<Byte, Memory>{memory}) {
    bytes_.reserve(failure_capacity);
  }

  template <typename Message>
  inline void send(const Message &message) {
    static_assert(MessageSchema<Message>::direction == Direction::server);
    const auto length = Codec::encodedSize(message);
    if (length > max_payload_size) {
      throw std::bad_alloc{};
    }

    bytes_.resize(length);
    Codec::encode(message, bytes_);
  }

  inline std::span<const Byte> payload() const noexcept {
    return bytes_;
  }

private:
  static constexpr std::size_t failure_capacity = 256;
  Vector<Byte, Memory> bytes_;
};

}
}
