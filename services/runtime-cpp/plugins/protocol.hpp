#pragma once

#include "../exchange_capture/exchange.hpp"
#include "effects.hpp"
#include "exchange_view.hpp"
#include "frame_reader.hpp"
#include "frame_size.hpp"
#include "frame_writer.hpp"

namespace telar::runtime::plugins {

enum class FrameKind : Byte {
  exchange = 1,
  effects = 2,
  error = 3
};

enum class EffectKind : Byte {
  notification = 3
};

class Protocol {
public:
  template <Allocator Memory>
  static std::span<const Byte> encodeExchange(std::span<Byte> output, ExchangeIdentity identity, const CapturedExchange<Memory> &exchange) {
    FrameWriter writer{output};
    writeExchange(writer, identity, exchange);
    return writer.finish();
  }

  template <Allocator Memory>
  static std::size_t exchangeBytes(const CapturedExchange<Memory> &exchange) {
    FrameSize size;
    writeExchange(size, {}, exchange);
    return size.finish();
  }

  static ExchangeView decodeExchange(std::span<const Byte> input) {
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

  static std::span<const Byte> encodeEffects(std::span<Byte> output, std::uint64_t event_id, const EffectBatch &batch) {
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

  static EffectReply decodeEffects(std::span<const Byte> input) {
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

  static std::span<const Byte> encodeError(std::span<Byte> output, std::uint64_t event_id, std::string_view message) {
    FrameWriter writer{output};
    writer.tag(FrameKind::error);
    writer.integer(event_id);
    writer.text(message.substr(0, Limits::error_bytes));
    return writer.finish();
  }

  static ErrorReply decodeError(std::span<const Byte> input) {
    FrameReader reader{input};
    reader.require(FrameKind::error);
    const ErrorReply reply{reader.integer<std::uint64_t>(), reader.text()};
    reader.finish();
    return reply;
  }

  static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t);

private:
  template <FrameOutput Output, Allocator Memory>
  static void writeExchange(Output &writer, ExchangeIdentity identity, const CapturedExchange<Memory> &exchange) {
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
    writeHalf(writer, exchange.request.get());
    writeHalf(writer, exchange.response.get());
  }

  static ExchangeProtocol exchangeProtocol(CaptureProtocol protocol) {
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
  static void writeHalf(Output &writer, const CaptureHalf<Memory> *half) {
    writer.boolean(half != nullptr);
    if (half == nullptr) {
      return;
    }

    writer.bytes(half->head.bytes());
    writer.bytes(half->body.bytes());
    writer.text(half->encoding());
    writer.boolean(half->body_decoded);
    writer.boolean(half->head.truncated);
    writer.boolean(half->body.truncated);
    writer.integer(half->status_code);
    writer.tag(half->outcome);
    writer.timestamp(half->finished_at_ms);
  }

  static std::optional<HalfView> readHalf(FrameReader &reader) {
    if (!reader.boolean()) {
      return std::nullopt;
    }

    HalfView half;
    half.head = reader.bytes();
    half.body = reader.bytes();
    half.encoding = reader.text();
    half.decoded = reader.boolean();
    reader.boolean();
    half.body_truncated = reader.boolean();
    half.status_code = reader.integer<std::uint16_t>();
    half.outcome = reader.tag(CaptureOutcome::reset);
    half.finished_at_ms = reader.timestamp();
    return half;
  }
};

}
