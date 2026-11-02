#pragma once

#include "../plugins/frame_reader.hpp"
#include "../plugins/frame_writer.hpp"
#include "fields.hpp"
#include <array>

namespace telar::runtime {

enum class HttpVersion : std::uint8_t { http10, http11, http2 };

struct HttpMessageLimits {
  static constexpr std::size_t body_bytes = 1024 * 1024;
  static constexpr std::size_t head_bytes = 64 * 1024;
  static constexpr std::size_t message_bytes = body_bytes + head_bytes + 8192;
};

struct HttpMessageView {
  struct Field { std::string_view name, value; };
  HttpVersion version = HttpVersion::http11;
  bool response = false;
  bool response_to_head = false;
  std::uint32_t stream = 0;
  std::string_view method, target, reason, scheme, authority;
  std::uint16_t status = 200;
  std::array<Field, HttpFields<SystemAllocator>::maximum_fields> headers, trailers;
  std::size_t header_count = 0;
  std::size_t trailer_count = 0;
  std::span<const Byte> body;
};

class HttpMessageCodec {
public:
  static auto encode(std::span<Byte> output, const HttpMessageView &message) -> std::span<const Byte> {
    validate(message);
    plugins::FrameWriter writer{output};
    writer.tag(message.version);
    writer.boolean(message.response);
    writer.boolean(message.response_to_head);
    writer.integer(message.stream);
    writer.text(message.method);
    writer.text(message.target);
    writer.text(message.reason);
    writer.text(message.scheme);
    writer.text(message.authority);
    writer.integer(message.status);
    writeFields(writer, std::span{message.headers}.first(message.header_count));
    writeFields(writer, std::span{message.trailers}.first(message.trailer_count));
    writer.bytes(message.body);
    return writer.finish();
  }

  static auto decode(std::span<const Byte> input) -> HttpMessageView {
    if (input.size() > HttpMessageLimits::message_bytes) { throw EncodingError{"HTTP message exceeds its frame limit"}; }
    plugins::FrameReader reader{input};
    HttpMessageView message;
    message.version = reader.tag(HttpVersion::http2);
    message.response = reader.boolean();
    message.response_to_head = reader.boolean();
    message.stream = reader.integer<std::uint32_t>();
    message.method = reader.text();
    message.target = reader.text();
    message.reason = reader.text();
    message.scheme = reader.text();
    message.authority = reader.text();
    message.status = reader.integer<std::uint16_t>();
    message.header_count = readFields(reader, message.headers);
    message.trailer_count = readFields(reader, message.trailers);
    message.body = reader.bytes();
    reader.finish();
    validate(message);
    return message;
  }

  template <typename Message>
  static auto encodeMessage(std::span<Byte> output, const Message &message) -> std::span<const Byte> {
    HttpMessageView view{.version = message.version, .response = message.response, .response_to_head = message.response_to_head, .stream = message.stream, .method = message.method, .target = message.target, .reason = message.reason, .scheme = message.scheme, .authority = message.authority, .status = message.status, .body = message.body};
    for (const auto &field : message.headers.fields()) { view.headers[view.header_count++] = {field.name(), field.value()}; }
    for (const auto &field : message.trailers.fields()) { view.trailers[view.trailer_count++] = {field.name(), field.value()}; }
    return encode(output, view);
  }

  template <typename Message>
  static void readMessage(Message &message, std::span<const Byte> input) {
    const auto view = decode(input);
    if (view.response != message.response || view.response_to_head != message.response_to_head || view.version != message.version || view.stream != message.stream) { throw EncodingError{"HTTP decision changed immutable transport metadata"}; }
    if (view.version != HttpVersion::http2 && (!view.scheme.empty() || !view.authority.empty())) { throw EncodingError{"HTTP/1 uses the request target and Host field"}; }
    message.method.assign(view.method);
    message.target.assign(view.target);
    message.reason.assign(view.reason);
    message.scheme.assign(view.scheme);
    message.authority.assign(view.authority);
    message.status = view.status;
    message.headers.clear();
    message.trailers.clear();
    for (const auto &field : std::span{view.headers}.first(view.header_count)) { message.headers.append(field.name, field.value); }
    for (const auto &field : std::span{view.trailers}.first(view.trailer_count)) { message.trailers.append(field.name, field.value); }
    message.body_materialized |= !std::ranges::equal(message.body, view.body);
    message.body.assign(view.body.begin(), view.body.end());
  }

private:
  static void writeFields(plugins::FrameWriter &writer, std::span<const HttpMessageView::Field> fields) {
    writer.integer(static_cast<std::uint16_t>(fields.size()));
    for (const auto &field : fields) { writer.text(field.name); writer.text(field.value); }
  }

  static auto readFields(plugins::FrameReader &reader, std::span<HttpMessageView::Field> fields) -> std::size_t {
    const auto count = reader.integer<std::uint16_t>();
    if (count > fields.size()) { throw EncodingError{"Too many HTTP fields"}; }
    for (auto &field : fields.first(count)) { field = {reader.text(), reader.text()}; }
    return count;
  }

  static void validate(const HttpMessageView &message) {
    if (static_cast<Byte>(message.version) > static_cast<Byte>(HttpVersion::http2) || message.header_count > message.headers.size() || message.trailer_count > message.trailers.size() || message.body.size() > HttpMessageLimits::body_bytes || message.method.size() > 64 || message.target.size() > 8192 || message.reason.size() > HttpMessageLimits::head_bytes || message.scheme.size() > 16 || message.authority.size() > 512) { throw EncodingError{"Invalid HTTP message bounds"}; }
    std::size_t bytes = message.method.size() + message.target.size() + message.reason.size() + message.scheme.size() + message.authority.size();
    if (bytes > HttpMessageLimits::head_bytes) { throw EncodingError{"HTTP metadata exceeds its limit"}; }
    for (const auto fields : {std::span{message.headers}.first(message.header_count), std::span{message.trailers}.first(message.trailer_count)}) {
      for (const auto &field : fields) {
        HttpFields<SystemAllocator>::validate(field.name, field.value);
        bytes += field.name.size() + field.value.size() + 4;
        if (bytes > HttpMessageLimits::head_bytes) { throw EncodingError{"HTTP metadata exceeds its limit"}; }
      }
    }
  }
};

}
