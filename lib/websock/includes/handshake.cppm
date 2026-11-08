module;
#include "tbc/view.hpp"

export module telar.websock.handshake;

import std;

import telar.base.text;

// Interface: includes/handshake.cppm
//
// Parses the client's opening handshake (RFC 6455 section 4.2.1) and nothing
// else of HTTP/1.1: a GET request head without a body. The parser does not
// allocate or copy: every view in the result points into the bytes it was given,
// which must outlive the result. Bytes past HandshakeRequest::size are already
// WebSocket frames.
export namespace telar::websock {

  // A head this long without its blank line is refused, so a client cannot make
  // the server buffer an unbounded request.
  inline constexpr std::size_t max_handshake_size = std::size_t{8} * 1024;

  enum class HandshakeError : std::uint8_t {
    // The head has not ended yet; read more bytes and parse again.
    incomplete,
    // Answer 431 Request Header Fields Too Large.
    too_large,
    // Answer 400 Bad Request.
    bad_request,
    // Answer 426 Upgrade Required with "Sec-WebSocket-Version: 13".
    unsupported_version,
  };

  struct HandshakeRequest final {
    // The origin-form target, such as "/path?query".
    std::string_view target;
    std::string_view host;
    // Empty when the client is not a browser and sent no Origin.
    std::string_view origin;
    // 24 base64 characters that decode to 16 bytes, as received.
    std::string_view key;
    // The comma-separated lists as received; empty when absent.
    std::string_view protocols;
    std::string_view extensions;
    // Bytes of the head, including its blank line.
    std::size_t size = 0;
  };

}

namespace telar::websock::handshake {

  enum class CharClass : std::uint8_t {
    token = 1U << 0U,
    value = 1U << 1U,
    target = 1U << 2U,
  };

  // RFC 9110 section 5.6.2 tokens, section 5.5 field values (visible ASCII,
  // obs-text, and inner SP/HTAB) and the visible ASCII of a request target.
  inline constexpr auto char_classes = [] {
    constexpr auto token = std::to_underlying(CharClass::token);
    constexpr auto value = std::to_underlying(CharClass::value);
    constexpr auto target = std::to_underlying(CharClass::target);

    constexpr std::size_t obs_text_first = 0x80;
    std::array<std::uint8_t, 256> table{};

    for (std::size_t character = '!'; character <= '~'; ++character) {
      table.at(character) = value | target;
    }

    for (std::size_t character = obs_text_first; character < table.size(); ++character) {
      table.at(character) = value;
    }

    table.at(' ') = value;
    table.at('\t') = value;

    for (const char character : std::string_view{"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"}) {
      table.at(static_cast<unsigned char>(character)) |= token;
    }

    return table;
  }();

  // Branchless, so the loop vectorizes. An unsigned char never exceeds the
  // table, so the compiler drops the bounds check of at().
  constexpr bool allOf(std::string_view text, CharClass wanted) noexcept {
    std::uint8_t classes = std::to_underlying(wanted);
    for (const char character : text) {
      classes &= char_classes.at(static_cast<unsigned char>(character));
    }
    return classes != 0;
  }

  inline constexpr std::string_view optional_whitespace = " \t";

  inline bool listContains(std::string_view list, std::string_view token) noexcept {
    runtime::TextFields items{list, ","};
    while (const auto item = items.next()) {
      if (runtime::asciiEqualIgnoreCase(runtime::trimText(*item, optional_whitespace), token)) {
        return true;
      }
    }
    return false;
  }

  inline bool validKey(std::string_view key) noexcept {
    constexpr std::size_t encoded_size = 24;
    constexpr std::size_t decoded_size = 16;
    std::array<std::uint8_t, decoded_size> decoded{};
    return key.size() == encoded_size && runtime::base64::decode<runtime::base64::Padding::required>(key, decoded) == decoded_size;
  }

  // "GET SP origin-form SP HTTP/1.minor": the method is case-sensitive and a
  // WebSocket upgrade needs HTTP/1.1 or a later 1.x.
  inline std::optional<std::string_view> requestTarget(std::string_view line) noexcept {
    constexpr std::string_view method = "GET ";
    constexpr std::string_view version = " HTTP/1.";
    if (!line.starts_with(method) || line.size() < method.size() + version.size() + 2) {
      return std::nullopt;
    }
    const char minor = line.back();
    line.remove_suffix(1);
    if (minor < '1' || minor > '9' || !line.ends_with(version)) {
      return std::nullopt;
    }
    const auto target = line.substr(method.size(), line.size() - method.size() - version.size());
    if (!target.starts_with('/') || !allOf(target, CharClass::target)) {
      return std::nullopt;
    }
    return target;
  }

  enum class Field : std::uint8_t {
    none,
    host,
    origin,
    upgrade,
    connection,
    key,
    version,
    protocol,
    extensions,
    content_length,
    transfer_encoding,
  };

  constexpr std::uint32_t fieldBit(Field field) noexcept {
    return 1U << std::to_underlying(field);
  }

  // Lists may repeat, and so may fields the handshake ignores; every other one must appear once.
  inline constexpr std::uint32_t repeatable_fields = fieldBit(Field::none) | fieldBit(Field::upgrade) | fieldBit(Field::connection);

  inline constexpr std::string_view host_name = "host";
  inline constexpr std::string_view origin_name = "origin";
  inline constexpr std::string_view upgrade_name = "upgrade";
  inline constexpr std::string_view connection_name = "connection";
  inline constexpr std::string_view key_name = "sec-websocket-key";
  inline constexpr std::string_view version_name = "sec-websocket-version";
  inline constexpr std::string_view protocol_name = "sec-websocket-protocol";
  inline constexpr std::string_view extensions_name = "sec-websocket-extensions";
  inline constexpr std::string_view content_length_name = "content-length";
  inline constexpr std::string_view transfer_encoding_name = "transfer-encoding";

  inline Field fieldNamed(std::string_view name) noexcept {
    using runtime::asciiEqualIgnoreCase;
    const auto named = [name](std::string_view candidate, Field field) {
      return asciiEqualIgnoreCase(name, candidate) ? field : Field::none;
    };
    // The length picks the one candidate a name can be, so each line pays for at
    // most two comparisons. Two names of one length fail to compile as two cases.
    switch (name.size()) {
    case host_name.size():
      return named(host_name, Field::host);
    case origin_name.size():
      return named(origin_name, Field::origin);
    case upgrade_name.size():
      return named(upgrade_name, Field::upgrade);
    case connection_name.size():
      return named(connection_name, Field::connection);
    case content_length_name.size():
      return named(content_length_name, Field::content_length);
    case key_name.size():
      static_assert(key_name.size() == transfer_encoding_name.size());
      if (asciiEqualIgnoreCase(name, key_name)) {
        return Field::key;
      }
      return named(transfer_encoding_name, Field::transfer_encoding);
    case version_name.size():
      return named(version_name, Field::version);
    case protocol_name.size():
      return named(protocol_name, Field::protocol);
    case extensions_name.size():
      return named(extensions_name, Field::extensions);
    default:
      return Field::none;
    }
  }

  // What the header lines established so far; its views borrow the head.
  struct Fields final {
    HandshakeRequest request;
    std::uint32_t seen = 0;
    bool upgrades = false;
    bool connection_upgrades = false;
    bool supported_version = false;
  };

  // Records one header line, without its CRLF, and answers whether it is valid.
  // No whitespace may precede the colon and a line may not continue the
  // previous one (obs-fold): both fail the token check of the name.
  [[nodiscard]] inline bool readField(tbc::view<Fields &, tbc::lt::a> fields, tbc::view<std::string_view, tbc::lt::a> line) noexcept {
    const auto colon = line.find(':');
    if (colon == std::string_view::npos) {
      return false;
    }
    const auto name = line.substr(0, colon);
    const auto value = runtime::trimText(line.substr(colon + 1), optional_whitespace);
    if (name.empty() || !allOf(name, CharClass::token) || !allOf(value, CharClass::value)) {
      return false;
    }

    const auto field = fieldNamed(name);
    const auto bit = fieldBit(field);
    if ((fields.seen & bit & ~repeatable_fields) != 0) {
      return false;
    }
    fields.seen |= bit;
    switch (field) {
    case Field::host:
      fields.request.host = value;
      return true;
    case Field::origin:
      fields.request.origin = value;
      return true;
    case Field::upgrade:
      fields.upgrades = fields.upgrades || listContains(value, "websocket");
      return true;
    case Field::connection:
      fields.connection_upgrades = fields.connection_upgrades || listContains(value, "upgrade");
      return true;
    case Field::key:
      fields.request.key = value;
      return true;
    case Field::version:
      fields.supported_version = value == "13";
      return true;
    case Field::protocol:
      fields.request.protocols = value;
      return true;
    case Field::extensions:
      fields.request.extensions = value;
      return true;
    // A body's bytes would otherwise be read as frames.
    case Field::content_length:
      return value == "0";
    case Field::transfer_encoding:
      return false;
    case Field::none:
      return true;
    }
    return false;
  }

}

export namespace telar::websock {

  // Parses a handshake from the start of `bytes`. A connection keeps appending
  // what it receives and calls this again while it answers `incomplete`.
  //
  // Stricter than RFC 9112 allows a server to be, because this server only has
  // to understand WebSocket clients: lines end in CRLF, the target is in
  // origin-form, and Sec-WebSocket-Protocol and Sec-WebSocket-Extensions may
  // not repeat (browsers send each once, joined with commas). A body is refused.
  inline std::expected<HandshakeRequest, HandshakeError> parseHandshake(std::string_view bytes) noexcept {
    using handshake::Field;
    using handshake::fieldBit;

    const auto window = bytes.substr(0, max_handshake_size);
    auto remaining = window;
    // Each call returns the next line without its CRLF, or why there is none yet.
    const auto nextLine = [&remaining, &bytes] -> std::expected<std::string_view, HandshakeError> {
      const auto end = remaining.find('\n');
      if (end == std::string_view::npos) {
        return std::unexpected{bytes.size() >= max_handshake_size ? HandshakeError::too_large : HandshakeError::incomplete};
      }
      // A bare LF ends nothing; a bare CR inside the line fails its character class.
      const auto line = remaining.substr(0, end);
      if (!line.ends_with('\r')) {
        return std::unexpected{HandshakeError::bad_request};
      }
      remaining = remaining.substr(end + 1);
      return line.substr(0, line.size() - 1);
    };

    const auto request_line = nextLine();
    if (!request_line) {
      return std::unexpected{request_line.error()};
    }
    const auto target = handshake::requestTarget(*request_line);
    if (!target) {
      return std::unexpected{HandshakeError::bad_request};
    }

    handshake::Fields fields{};
    fields.request.target = *target;
    while (true) {
      const auto line = nextLine();
      if (!line) {
        return std::unexpected{line.error()};
      }
      if (line->empty()) {
        break;
      }
      if (!handshake::readField(fields, *line)) {
        return std::unexpected{HandshakeError::bad_request};
      }
    }

    if (fields.request.host.empty() || !fields.upgrades || !fields.connection_upgrades || !handshake::validKey(fields.request.key) ||
        (fields.seen & fieldBit(Field::version)) == 0) {
      return std::unexpected{HandshakeError::bad_request};
    }
    if (!fields.supported_version) {
      return std::unexpected{HandshakeError::unsupported_version};
    }
    fields.request.size = window.size() - remaining.size();
    return fields.request;
  }

}
