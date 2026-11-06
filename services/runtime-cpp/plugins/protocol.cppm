module;

#include "telar_client/serializers/telar_messages.hpp"
#include <chrono>
#include <cstddef>
#include <cstdint>


#include <string_view>
#include <optional>
#include <span>


#include "telar_client/codecs/telar_wire.hpp"


#include <bit>


#include <algorithm>
#include <atomic>
#include <cassert>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <array>
#include <stdexcept>

export module telar.runtime.plugins.protocol;

export import telar.plugins;


export import telar.runtime.exchange_capture.exchange;

// Interface: plugins/effects.cppm
export {
namespace telar::runtime::plugins {

struct EffectBatch {
  std::array<NotificationBody, Limits::effects> notifications;
  std::uint8_t count = 0;
};

struct EffectReply {
  std::uint64_t event_id = 0;
  EffectBatch batch;
};

struct ErrorReply {
  std::uint64_t event_id = 0;
  std::string_view message{};
};

}
}

// Interface: plugins/exchange_view.cppm
export {
namespace telar::runtime::plugins {

enum class ExchangeProtocol : std::uint8_t {
  http11,
  h2,
  upgraded
};

struct HalfView {
  std::span<const std::uint8_t> head{};
  std::span<const std::uint8_t> body{};
  std::string_view encoding{};
  bool decoded = false;
  bool body_truncated = false;
  std::uint16_t status_code = 0;
  CaptureOutcome outcome = CaptureOutcome::failed;
  std::int64_t finished_at_ms = 0;
  bool head_truncated = false;
};

struct ExchangeIdentity {
  std::uint64_t id = 0;
  std::uint64_t generation = 0;
};

struct ExchangeView {
  ExchangeIdentity identity;
  ExchangeProtocol protocol = ExchangeProtocol::http11;
  CaptureKey key;
  std::string_view host{};
  std::string_view method{};
  std::string_view target{};
  std::int64_t started_at_ms = 0;
  std::optional<HalfView> request;
  std::optional<HalfView> response;
};

}
}

// Interface: plugins/frame_output.cppm
export {
namespace telar::runtime::plugins {

template <typename Output>
concept FrameOutput = requires(Output &output, std::span<const Byte> bytes, std::string_view text) {
  { output.integer(std::uint64_t{}) } -> std::same_as<void>;
  { output.integer(std::uint32_t{}) } -> std::same_as<void>;
  { output.integer(std::uint16_t{}) } -> std::same_as<void>;
  { output.integer(Byte{}) } -> std::same_as<void>;
  { output.tag(std::byte{}) } -> std::same_as<void>;
  { output.timestamp(std::int64_t{}) } -> std::same_as<void>;
  { output.boolean(false) } -> std::same_as<void>;
  { output.bytes(bytes) } -> std::same_as<void>;
  { output.text(text) } -> std::same_as<void>;
};

}
}

// Interface: plugins/frame_reader.cppm
export {
namespace telar::runtime::plugins {

class FrameReader {
public:
  inline explicit FrameReader(std::span<const Byte> input) noexcept : remaining_(input) {}

  template <std::unsigned_integral Integer>
  inline Integer integer() {
    return LittleEndian<Integer>::decode(remaining_);
  }

  inline std::int64_t timestamp() { return std::bit_cast<std::int64_t>(integer<std::uint64_t>()); }
  inline bool boolean() { return BoolByte::decode(remaining_); }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  Enum tag(Enum maximum) {
    const auto value = integer<Byte>();
    if (value > static_cast<Byte>(maximum)) {
      throw EncodingError{"Unknown tap enumeration value"};
    }
    return static_cast<Enum>(value);
  }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  void require(Enum expected) {
    if (integer<Byte>() != static_cast<Byte>(expected)) {
      throw EncodingError{"Unexpected tap frame tag"};
    }
  }

  inline std::span<const Byte> bytes() {
    const auto length = integer<std::uint32_t>();
    if (length > remaining_.size()) {
      throw EncodingError{"Truncated tap field"};
    }
    const auto value = remaining_.first(length);
    remaining_ = remaining_.subspan(length);
    return value;
  }

  inline std::string_view text() {
    const auto value = bytes();
    return {reinterpret_cast<const char *>(value.data()), value.size()};
  }

  inline void finish() const {
    if (!remaining_.empty()) {
      throw EncodingError{"Trailing tap frame bytes"};
    }
  }

private:
  std::span<const Byte> remaining_;
};

}
}

// Interface: plugins/frame_size.cppm
export {
namespace telar::runtime::plugins {

class FrameSize {
public:
  template <std::unsigned_integral Integer>
  inline void integer(Integer) { add(sizeof(Integer)); }

  inline void timestamp(std::int64_t) { integer(std::uint64_t{}); }
  inline void boolean(bool) { integer(Byte{}); }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  void tag(Enum) { integer(Byte{}); }

  inline void bytes(std::span<const Byte> value) {
    if (value.size() > UINT32_MAX) {
      throw EncodingError{"Tap field exceeds its frame buffer"};
    }
    integer(std::uint32_t{});
    add(value.size());
  }

  inline void text(std::string_view value) {
    bytes({reinterpret_cast<const Byte *>(value.data()), value.size()});
  }

  inline std::size_t finish() const noexcept { return size_; }

private:
  inline void add(std::size_t count) { size_ = checkedWireSize(size_, count); }

  std::size_t size_ = 0;
};

static_assert(FrameOutput<FrameSize>);

}
}

// Interface: plugins/frame_writer.cppm
export {
namespace telar::runtime::plugins {

class FrameWriter {
public:
  inline explicit FrameWriter(std::span<Byte> output) noexcept : output_(output), remaining_(output) {}

  template <std::unsigned_integral Integer>
  inline void integer(Integer value) {
    LittleEndian<Integer>::encode(value, remaining_);
  }

  inline void timestamp(std::int64_t value) { integer(std::bit_cast<std::uint64_t>(value)); }
  inline void boolean(bool value) { BoolByte::encode(value, remaining_); }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  void tag(Enum value) {
    integer(static_cast<Byte>(value));
  }

  inline void bytes(std::span<const Byte> value) {
    if (value.size() > UINT32_MAX || remaining_.size() < sizeof(std::uint32_t) || value.size() > remaining_.size() - sizeof(std::uint32_t)) {
      throw EncodingError{"Tap field exceeds its frame buffer"};
    }

    integer(static_cast<std::uint32_t>(value.size()));
    if (!value.empty()) {
      std::memcpy(remaining_.data(), value.data(), value.size());
    }
    remaining_ = remaining_.subspan(value.size());
  }

  inline void text(std::string_view value) {
    bytes({reinterpret_cast<const Byte *>(value.data()), value.size()});
  }

  inline void append(std::span<const Byte> value) {
    if (value.size() > remaining_.size()) { throw EncodingError{"Tap data exceeds its frame buffer"}; }
    if (!value.empty()) { std::memcpy(remaining_.data(), value.data(), value.size()); }
    remaining_ = remaining_.subspan(value.size());
  }

  inline std::span<const Byte> finish() const noexcept { return output_.first(output_.size() - remaining_.size()); }

private:
  std::span<Byte> output_;
  std::span<Byte> remaining_;
};

}
}

// Interface: plugins/protocol.cppm
export {
namespace telar::runtime::plugins {

enum class FrameKind : Byte {
  exchange = 1,
  effects = 2,
  error = 3,
  traffic_setup = 4,
  traffic_event = 5,
  traffic_reply = 6,
  traffic_control_event = 7
};

enum class EffectKind : Byte {
  notification = 3
};

class Protocol {
public:
  template <Allocator Memory>
  inline static std::span<const Byte> encodeExchange(std::span<Byte> output, ExchangeIdentity identity, const CapturedExchange<Memory> &exchange, std::size_t part_limit = SIZE_MAX) {
    FrameWriter writer{output};
    writeExchange(writer, identity, exchange, part_limit);
    return writer.finish();
  }

  template <Allocator Memory>
  inline static std::size_t exchangeBytes(const CapturedExchange<Memory> &exchange) {
    FrameSize size;
    writeExchange(size, {}, exchange);
    return size.finish();
  }

  inline static ExchangeView decodeExchange(std::span<const Byte> input) {
    FrameReader reader{input};
    reader.require(FrameKind::exchange);
    ExchangeView exchange;
    exchange.identity.id = reader.integer<std::uint64_t>();
    exchange.identity.generation = reader.integer<std::uint64_t>();
    exchange.protocol = reader.tag(ExchangeProtocol::upgraded);
    exchange.key.connection = reader.integer<std::uint64_t>();
    exchange.key.stream = reader.integer<std::uint32_t>();
    exchange.host = reader.text();
    exchange.method = reader.text();
    exchange.target = reader.text();
    exchange.started_at_ms = reader.timestamp();
    exchange.request = readHalf(reader);
    exchange.response = readHalf(reader);
    reader.finish();
    return exchange;
  }

  inline static std::span<const Byte> encodeEffects(std::span<Byte> output, std::uint64_t event_id, const EffectBatch &batch) {
    if (batch.count > Limits::effects) {
      throw EncodingError{"Tap returned too many effects"};
    }

    FrameWriter writer{output};
    writer.tag(FrameKind::effects);
    writer.integer(event_id);
    writer.integer(batch.count);
    for (const auto &notification : std::span{batch.notifications}.first(batch.count)) {
      writer.tag(EffectKind::notification);
      writer.tag(notification.level);
      writer.integer(notification.duration_ms);
      writer.text(notification.title);
      writer.text(notification.message);
    }
    return writer.finish();
  }

  inline static EffectReply decodeEffects(std::span<const Byte> input) {
    FrameReader reader{input};
    reader.require(FrameKind::effects);
    EffectReply result;
    result.event_id = reader.integer<std::uint64_t>();
    result.batch.count = reader.integer<Byte>();
    if (result.batch.count > Limits::effects) {
      throw EncodingError{"Tap returned too many effects"};
    }

    for (auto &notification : std::span{result.batch.notifications}.first(result.batch.count)) {
      reader.require(EffectKind::notification);
      notification.level = reader.tag(NotificationLevel::failure);
      notification.duration_ms = reader.integer<std::uint32_t>();
      notification.title = reader.text();
      notification.message = reader.text();
    }
    reader.finish();
    return result;
  }

  inline static std::span<const Byte> encodeError(std::span<Byte> output, std::uint64_t event_id, std::string_view message) {
    FrameWriter writer{output};
    writer.tag(FrameKind::error);
    writer.integer(event_id);
    writer.text(message.substr(0, Limits::error_bytes));
    return writer.finish();
  }

  inline static ErrorReply decodeError(std::span<const Byte> input) {
    FrameReader reader{input};
    reader.require(FrameKind::error);
    const ErrorReply reply{reader.integer<std::uint64_t>(), reader.text()};
    reader.finish();
    return reply;
  }

  static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t);

private:
  template <FrameOutput Output, Allocator Memory>
  inline static void writeExchange(Output &writer, ExchangeIdentity identity, const CapturedExchange<Memory> &exchange, std::size_t part_limit = SIZE_MAX) {
    const auto *representative = exchange.request ? exchange.request.get() : exchange.response.get();
    if (representative == nullptr) {
      throw EncodingError{"Cannot encode an empty capture"};
    }

    writer.tag(FrameKind::exchange);
    writer.integer(identity.id);
    writer.integer(identity.generation);
    writer.tag(exchangeProtocol(representative->protocol));
    writer.integer(representative->key.connection);
    writer.integer(representative->key.stream);
    writer.text(representative->host());
    writer.text(representative->method());
    writer.text(representative->target());
    writer.timestamp(representative->started_at_ms);
    writeHalf(writer, exchange.request.get(), part_limit);
    writeHalf(writer, exchange.response.get(), part_limit);
  }

  inline static ExchangeProtocol exchangeProtocol(CaptureProtocol protocol) {
    switch (protocol) {
    case CaptureProtocol::http1:
      return ExchangeProtocol::http11;
    case CaptureProtocol::http2:
      return ExchangeProtocol::h2;
    case CaptureProtocol::upgraded:
      return ExchangeProtocol::upgraded;
    }
    throw EncodingError{"Unknown captured protocol"};
  }

  template <FrameOutput Output, Allocator Memory>
  inline static void writeHalf(Output &writer, const CaptureHalf<Memory> *half, std::size_t part_limit) {
    writer.boolean(half != nullptr);
    if (half == nullptr) {
      return;
    }

    writer.bytes(half->head.bytes().first(std::min(half->head.size(), part_limit)));
    writer.bytes(half->body.bytes().first(std::min(half->body.size(), part_limit)));
    writer.text(half->encoding());
    writer.boolean(half->body_decoded);
    writer.boolean(half->head.truncated || half->head.size() > part_limit);
    writer.boolean(half->body.truncated || half->body.size() > part_limit);
    writer.integer(half->status_code);
    writer.tag(half->outcome);
    writer.timestamp(half->finished_at_ms);
  }

  inline static std::optional<HalfView> readHalf(FrameReader &reader) {
    if (!reader.boolean()) {
      return std::nullopt;
    }

    HalfView half;
    half.head = reader.bytes();
    half.body = reader.bytes();
    half.encoding = reader.text();
    half.decoded = reader.boolean();
    half.head_truncated = reader.boolean();
    half.body_truncated = reader.boolean();
    half.status_code = reader.integer<std::uint16_t>();
    half.outcome = reader.tag(CaptureOutcome::reset);
    half.finished_at_ms = reader.timestamp();
    return half;
  }
};

}
}
