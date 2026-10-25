#pragma once

#include "../proxy/socket.hpp"
#include <array>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::runtime {

enum class HttpProtocol {
  http11,
  http2
};

class AlpnOffer {
public:
  enum class Read {
    pending,
    complete,
    ended
  };

  Read peek(int socket) noexcept {
    const auto count = ::recv(socket, bytes_.data(), bytes_.size(), MSG_PEEK);
    if (count <= 0) {
      return count < 0 && socketWouldBlock(errno) ? Read::pending : Read::ended;
    }
    if (static_cast<std::size_t>(count) < record_header_bytes) {
      return Read::pending;
    }

    const std::size_t record_bytes = (std::size_t{bytes_[3]} << 8) | bytes_[4];
    if (bytes_[0] != handshake_record || record_bytes > maximum_record_bytes) {
      return Read::complete;
    }
    if (static_cast<std::size_t>(count) < record_header_bytes + record_bytes) {
      return Read::pending;
    }
    parse(std::span{bytes_}.subspan(record_header_bytes, record_bytes));
    return Read::complete;
  }

  void parse(std::span<const std::uint8_t> handshake) noexcept {
    offered_ = both;
    Cursor record{handshake};
    if (record.byte() != client_hello) {
      return;
    }
    record.take(handshake_length_bytes + version_bytes + random_bytes);
    record.take(record.byte());
    record.take(record.word());
    record.take(record.byte());
    const auto extension_bytes = record.take(record.word());
    if (record.failed()) {
      return;
    }

    Cursor extensions{extension_bytes};
    while (!extensions.empty()) {
      const auto kind = extensions.word();
      const auto body = extensions.take(extensions.word());
      if (extensions.failed()) {
        return;
      }
      if (kind == alpn_extension) {
        protocols(body);
        return;
      }
    }
    offered_ = none;
  }

  std::span<const std::uint8_t> encoded() const noexcept {
    switch (offered_) {
    case http2:
      return std::span{protocol_names}.first(http2_bytes);
    case http11:
      return std::span{protocol_names}.subspan(http2_bytes);
    case both:
      return protocol_names;
    default:
      return {};
    }
  }

private:
  class Cursor {
  public:
    explicit Cursor(std::span<const std::uint8_t> bytes) noexcept
        : bytes_(bytes) {}

    std::span<const std::uint8_t> take(std::size_t count) noexcept {
      if (count > bytes_.size()) {
        failed_ = true;
        bytes_ = {};
        return {};
      }
      const auto result = bytes_.first(count);
      bytes_ = bytes_.subspan(count);
      return result;
    }

    std::uint8_t byte() noexcept {
      const auto value = take(1);
      return value.empty() ? 0 : value.front();
    }

    std::uint16_t word() noexcept {
      const auto value = take(2);
      return value.empty() ? 0 : static_cast<std::uint16_t>((std::uint16_t{value[0]} << 8) | value[1]);
    }

    bool failed() const noexcept {
      return failed_;
    }

    bool empty() const noexcept {
      return bytes_.empty();
    }

    std::size_t remaining() const noexcept {
      return bytes_.size();
    }

  private:
    std::span<const std::uint8_t> bytes_;
    bool failed_ = false;
  };

  void protocols(std::span<const std::uint8_t> extension) noexcept {
    Cursor names{extension};
    const auto declared = names.word();
    if (names.failed() || declared != names.remaining()) {
      return;
    }

    unsigned selected = none;
    while (!names.empty()) {
      const auto length = names.byte();
      const auto bytes = names.take(length);
      if (names.failed()) {
        return;
      }
      const std::string_view name{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
      if (name == "h2") {
        selected |= http2;
      } else if (name == "http/1.1") {
        selected |= http11;
      }
    }
    offered_ = selected;
  }

  enum Protocols : unsigned {
    none = 0,
    http2 = 1,
    http11 = 2,
    both = http2 | http11
  };

  static constexpr std::uint8_t handshake_record = 22;
  static constexpr std::uint8_t client_hello = 1;
  static constexpr std::uint16_t alpn_extension = 16;
  static constexpr std::size_t record_header_bytes = 5;
  static constexpr std::size_t maximum_record_bytes = 16 * 1024;
  static constexpr std::size_t handshake_length_bytes = 3;
  static constexpr std::size_t version_bytes = 2;
  static constexpr std::size_t random_bytes = 32;
  static constexpr std::size_t http2_bytes = 3;
  static constexpr std::array<std::uint8_t, 12> protocol_names{2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
  std::array<std::uint8_t, record_header_bytes + maximum_record_bytes> bytes_;
  unsigned offered_ = both;
};

}
