#pragma once

#include "../http1/head.hpp"
#include "content_codec.hpp"
#include "fields.hpp"
#include "message_codec.hpp"
#include <charconv>

namespace telar::runtime {

template <Allocator Memory>
class HttpMessage {
  using Secure = ErasingAllocator<Memory>;
  using Text = String<Secure>;

  Memory &upstream_;
  Secure memory_;

public:
  using Bytes = Vector<std::uint8_t, Secure>;

  explicit HttpMessage(Memory &memory, bool response = false) : upstream_(memory), memory_(memory), response(response), method(AllocatorRef<char, Secure>{memory_}), target(AllocatorRef<char, Secure>{memory_}), reason(AllocatorRef<char, Secure>{memory_}), scheme(AllocatorRef<char, Secure>{memory_}), authority(AllocatorRef<char, Secure>{memory_}), headers(memory), trailers(memory), body(AllocatorRef<std::uint8_t, Secure>{memory_}) {}
  HttpMessage(const HttpMessage &) = delete;
  HttpMessage &operator=(const HttpMessage &) = delete;

  auto readHttp1Head(std::string_view input, bool head_response = false) -> Http1Head {
    if (input.size() > Http1Head::capacity || !input.ends_with("\r\n\r\n") || input.find("\r\n\r\n") != input.size() - 4) { throw std::invalid_argument{"Incomplete HTTP head"}; }
    const auto analyzed = Http1Head::analyze(input, response, head_response);
    if (!analyzed) { throw std::invalid_argument{"Invalid HTTP framing"}; }

    headers.clear();
    trailers.clear();
    body.clear();
    method.clear();
    target.clear();
    reason.clear();
    scheme.clear();
    authority.clear();
    stream = 0;
    body_materialized = false;
    response_to_head = head_response;
    TextFields lines{input, "\r\n"};
    const auto start = *lines.next();
    if (response) {
      if (start.size() < status_line_prefix_bytes || start[8] != ' ' || start[12] != ' ') { throw std::invalid_argument{"Invalid HTTP status line"}; }
      version = readVersion(start.substr(0, 8));
      status = analyzed->status;
      reason.assign(start.substr(status_line_prefix_bytes));
      HttpFields<Memory>::validate("reason", reason);
    } else {
      const auto first = start.find(' ');
      const auto last = start.rfind(' ');
      if (first == std::string_view::npos || first == last) { throw std::invalid_argument{"Invalid HTTP request line"}; }
      method.assign(start.substr(0, first));
      target.assign(start.substr(first + 1, last - first - 1));
      version = readVersion(start.substr(last + 1));
      validateRequest();
    }

    while (const auto line = lines.next()) {
      if (line->empty()) { break; }
      const auto colon = line->find(':');
      if (colon == std::string_view::npos) { throw std::invalid_argument{"Invalid HTTP field line"}; }
      headers.append(line->substr(0, colon), trimText(line->substr(colon + 1), " \t"));
    }

    validateHost();
    validateLengths();
    return *analyzed;
  }

  void decodeBody(std::span<const std::uint8_t> wire) {
    const auto coding = contentEncoding();
    auto decoded = HttpContentCodec{upstream_}.decode(wire, coding, maximum_body_bytes);
    body.assign(decoded.bytes().begin(), decoded.bytes().end());
    body_materialized = true;
  }

  bool bodyless() const noexcept { return response && (response_to_head || status < 200 || status == 204 || status == 205 || status == 304); }

  auto encodeBody() -> DecodedBody<Memory> {
    return HttpContentCodec{upstream_}.encode(body, contentEncoding(), maximum_body_bytes + content_overhead_bytes);
  }

  void validateHttp2() const {
    if (version != HttpVersion::http2 || body.size() > maximum_body_bytes || headers.bytes() > HttpFields<Memory>::maximum_bytes - trailers.bytes()) { throw std::invalid_argument{"Invalid HTTP/2 message bounds"}; }
    if (response) {
      if (status < 100 || status > 599 || status == 101) { throw std::invalid_argument{"Invalid HTTP/2 status"}; }
    } else {
      if (!HttpFields<Memory>::token(method) || method.size() > maximum_method_bytes || authority.empty() || authority.size() > 512) { throw std::invalid_argument{"Invalid HTTP/2 request"}; }
      if (method == "CONNECT") {
        if (!scheme.empty() || !target.empty()) { throw std::invalid_argument{"Invalid HTTP/2 CONNECT"}; }
      } else {
        validateRequest();
        if ((scheme != "http" && scheme != "https") || (!target.starts_with('/') && !(method == "OPTIONS" && target == "*"))) { throw std::invalid_argument{"Invalid HTTP/2 target"}; }
      }
      if (std::ranges::any_of(authority, [](unsigned char byte) { return byte <= 32 || byte >= 127 || std::string_view{"/,#?@\\"}.contains(byte); })) { throw std::invalid_argument{"Invalid HTTP/2 authority"}; }
    }
    validateTrailers();
    for (const auto &field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "connection") || asciiEqualIgnoreCase(field.name(), "keep-alive") || asciiEqualIgnoreCase(field.name(), "proxy-connection") || asciiEqualIgnoreCase(field.name(), "transfer-encoding") || asciiEqualIgnoreCase(field.name(), "upgrade") || (asciiEqualIgnoreCase(field.name(), "te") && !asciiEqualIgnoreCase(field.value(), "trailers"))) { throw std::invalid_argument{"Connection-specific HTTP/2 field"}; }
    }
  }

  // Framing is regenerated from the complete entity, never copied from an application's length field.
  auto serializeHttp1() -> Bytes {
    if (version == HttpVersion::http2) { throw std::invalid_argument{"HTTP/2 messages require an HTTP/2 endpoint"}; }
    if (body.size() > maximum_body_bytes || headers.bytes() > HttpFields<Memory>::maximum_bytes - trailers.bytes()) { throw std::length_error{"HTTP message exceeds its limit"}; }
    if (response) {
      if (status < 100 || status > 599) { throw std::invalid_argument{"Invalid HTTP status"}; }
      HttpFields<Memory>::validate("reason", reason);
    } else { validateRequest(); validateHost(); }

    const bool without_body = bodyless();
    const bool chunked = !without_body && !trailers.fields().empty();
    if (chunked && version == HttpVersion::http10) { throw std::invalid_argument{"HTTP/1.0 cannot carry trailers"}; }
    validateTrailers();
    Bytes output{AllocatorRef<std::uint8_t, Secure>{memory_}};
    const auto protocol = version == HttpVersion::http10 ? "HTTP/1.0" : "HTTP/1.1";
    if (response) {
      append(output, protocol); append(output, " "); number(output, status); append(output, " "); append(output, reason); append(output, "\r\n");
    } else {
      append(output, method); append(output, " "); append(output, target); append(output, " "); append(output, protocol); append(output, "\r\n");
    }
    for (const auto &field : headers.fields()) {
      if (!framingField(field.name())) { fieldLine(output, field.name(), field.value()); }
    }

    if (without_body) {
      if (response_to_head && status >= 200 && status != 204 && status != 205 && status != 304 && (body_materialized || !body.empty())) {
        const auto entity = encodeBody();
        append(output, "Content-Length: "); number(output, entity.size); append(output, "\r\n");
      } else if (status >= 200 && status != 204 && status != 205 && (response_to_head || status == 304) && headers.get("content-length")) {
        validateLengths();
        fieldLine(output, "Content-Length", *headers.get("content-length"));
      } else if (status == 205) { fieldLine(output, "Content-Length", "0"); }
      append(output, "\r\n");
      validateHeadSize(output);
      return output;
    }

    const auto encoding = contentEncoding();
    auto entity = HttpContentCodec{upstream_}.encode(body, encoding, maximum_body_bytes + content_overhead_bytes);
    if (chunked) {
      fieldLine(output, "Transfer-Encoding", "chunked");
      append(output, "Trailer: ");
      bool first = true;
      for (const auto &field : trailers.fields()) {
        if (!first) { append(output, ", "); }
        append(output, field.name());
        first = false;
      }
      append(output, "\r\n\r\n");
      validateHeadSize(output);
      if (entity.size != 0) {
        number(output, entity.size, 16); append(output, "\r\n"); append(output, entity.bytes()); append(output, "\r\n");
      }
      append(output, "0\r\n");
      for (const auto &field : trailers.fields()) { fieldLine(output, field.name(), field.value()); }
      append(output, "\r\n");
    } else {
      append(output, "Content-Length: "); number(output, entity.size); append(output, "\r\n\r\n");
      validateHeadSize(output);
      append(output, entity.bytes());
    }
    return output;
  }

  static constexpr std::size_t maximum_body_bytes = HttpMessageLimits::body_bytes;
  bool response;
  bool response_to_head = false;
  bool body_materialized = false;
  HttpVersion version = HttpVersion::http11;
  std::uint16_t status = 200;
  std::uint32_t stream = 0;
  Text method, target, reason, scheme, authority;
  HttpFields<Memory> headers, trailers;
  Bytes body;

private:
  static HttpVersion readVersion(std::string_view value) {
    if (value == "HTTP/1.1") { return HttpVersion::http11; }
    if (value == "HTTP/1.0") { return HttpVersion::http10; }
    throw std::invalid_argument{"Unsupported HTTP version"};
  }

  void validateRequest() const {
    if (!HttpFields<Memory>::token(method) || method.size() > maximum_method_bytes || target.empty() || target.size() > maximum_target_bytes || std::ranges::any_of(target, [](unsigned char byte) { return byte <= 32 || byte >= 127; })) { throw std::invalid_argument{"Invalid HTTP request line"}; }
  }

  void validateHost() const {
    if (response) { return; }
    std::size_t hosts = 0;
    for (const auto &field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "host")) {
        if (field.value().empty() || std::ranges::any_of(field.value(), [](unsigned char byte) { return byte <= 32 || byte >= 127 || std::string_view{"/,#?@\\"}.contains(byte); })) { throw std::invalid_argument{"Invalid HTTP Host field"}; }
        ++hosts;
      }
    }
    if (hosts > 1 || (version == HttpVersion::http11 && hosts != 1)) { throw std::invalid_argument{"HTTP request requires one Host field"}; }
  }

  void validateLengths() const {
    std::optional<std::size_t> length;
    bool transfer = false;
    for (const auto &field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "content-length")) {
        TextFields values{field.value(), ","};
        while (const auto value = values.next()) {
          const auto decimal = trimText(*value, " \t");
          if (decimal.empty() || !std::ranges::all_of(decimal, [](unsigned char byte) { return byte >= '0' && byte <= '9'; })) { throw std::invalid_argument{"Invalid HTTP length"}; }
          const auto parsed = parseHttpNumber<10>(decimal);
          if (!parsed || (length && *length != *parsed)) { throw std::invalid_argument{"Conflicting HTTP lengths"}; }
          length = parsed;
        }
      }
      if (asciiEqualIgnoreCase(field.name(), "transfer-encoding")) {
        if (transfer || !asciiEqualIgnoreCase(field.value(), "chunked")) { throw std::invalid_argument{"Unsupported HTTP transfer coding"}; }
        transfer = true;
      }
    }
    if (transfer && length) { throw std::invalid_argument{"Ambiguous HTTP framing"}; }
  }

  void validateTrailers() const {
    for (const auto &field : trailers.fields()) {
      constexpr std::array forbidden{"host", "content-encoding", "content-type", "content-range", "connection", "authorization", "proxy-authorization", "proxy-authenticate", "www-authenticate", "cookie", "set-cookie", "cache-control", "max-forwards", "te", "upgrade", "range"};
      if (framingField(field.name()) || std::ranges::any_of(forbidden, [&](std::string_view name) { return asciiEqualIgnoreCase(field.name(), name); })) { throw std::invalid_argument{"Unsafe HTTP trailer"}; }
      for (const auto &header : headers.fields()) {
        if (!asciiEqualIgnoreCase(header.name(), "connection")) { continue; }
        TextFields tokens{header.value(), ","};
        while (const auto token = tokens.next()) {
          if (asciiEqualIgnoreCase(field.name(), trimText(*token, " \t"))) { throw std::invalid_argument{"Hop-by-hop HTTP trailer"}; }
        }
      }
    }
  }

  auto contentEncoding() -> Text {
    Text encoding{AllocatorRef<char, Secure>{memory_}};
    for (const auto &field : headers.fields()) {
      if (asciiEqualIgnoreCase(field.name(), "content-encoding")) {
        if (trimText(field.value(), " \t").empty()) { throw std::invalid_argument{"Empty HTTP content coding"}; }
        if (!encoding.empty()) { encoding += ", "; }
        encoding += field.value();
      }
    }
    return encoding;
  }

  static bool framingField(std::string_view name) noexcept {
    return asciiEqualIgnoreCase(name, "content-length") || asciiEqualIgnoreCase(name, "transfer-encoding") || asciiEqualIgnoreCase(name, "trailer");
  }

  static void append(Bytes &output, std::span<const std::uint8_t> bytes) {
    if (bytes.size() > maximum_wire_bytes - output.size()) { throw std::length_error{"HTTP wire message exceeds its limit"}; }
    output.insert(output.end(), bytes.begin(), bytes.end());
  }

  static void append(Bytes &output, std::string_view text) {
    append(output, std::span{reinterpret_cast<const std::uint8_t *>(text.data()), text.size()});
  }

  static void number(Bytes &output, std::size_t value, int base = 10) {
    std::array<char, std::numeric_limits<std::size_t>::digits10 + 1> text;
    const auto result = std::to_chars(text.data(), text.data() + text.size(), value, base);
    if (result.ec != std::errc{}) { throw std::length_error{"Invalid HTTP length"}; }
    append(output, std::string_view{text.data(), result.ptr});
  }

  static void fieldLine(Bytes &output, std::string_view name, std::string_view value) {
    append(output, name); append(output, ": "); append(output, value); append(output, "\r\n");
  }

  static void validateHeadSize(const Bytes &head) {
    if (head.size() > Http1Head::capacity) { throw std::length_error{"HTTP head exceeds its limit"}; }
  }

  static constexpr std::size_t maximum_method_bytes = 64;
  static constexpr std::size_t maximum_target_bytes = 8192;
  static constexpr std::size_t status_line_prefix_bytes = 13;
  static constexpr std::size_t content_overhead_bytes = 64 * 1024;
  static constexpr std::size_t maximum_wire_bytes = maximum_body_bytes + 3 * content_overhead_bytes;
};

}
