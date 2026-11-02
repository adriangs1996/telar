#pragma once

#include "../proxy/socket.hpp"
#include "../proxy/hostname.hpp"
#include "../memory/fixed_text.hpp"
#include <array>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::runtime {

enum class HttpProtocol {
  http11,
  http2,
  other
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
    tls_ = bytes_[0] == handshake_record;
    if (!tls_) { return Read::complete; }

    const auto available = static_cast<std::size_t>(count);
    std::size_t cursor = 0, collected = 0;
    while (cursor < available) {
      if (available - cursor < record_header_bytes) { return incomplete(available); }
      const auto *header = bytes_.data() + cursor;
      const std::size_t length = (std::size_t{header[3]} << 8) | header[4];
      if (header[0] != handshake_record || header[1] != 3 || length == 0 || length > maximum_record_bytes) { return Read::complete; }
      if (available - cursor - record_header_bytes < length) { return incomplete(available); }
      std::memmove(bytes_.data() + collected, header + record_header_bytes, length);
      collected += length;
      cursor += record_header_bytes + length;
      if (collected >= 4) {
        const auto expected = (std::size_t{bytes_[1]} << 16) | (std::size_t{bytes_[2]} << 8) | bytes_[3];
        if (expected > maximum_hello_bytes - 4 || bytes_[0] != client_hello) { return Read::complete; }
        if (collected >= expected + 4) {
          parse(std::span{bytes_}.first(expected + 4));
          return Read::complete;
        }
      }
    }
    return incomplete(available);
  }

  void parse(std::span<const std::uint8_t> handshake) noexcept {
    protocols_ = {};
    valid_ = false;
    encrypted_ = false;
    server_name_.assign({});
    Cursor record{handshake};
    if (record.byte() != client_hello) { return; }
    const auto declared = record.take(handshake_length_bytes);
    if (declared.size() != 3 || ((std::size_t{declared[0]} << 16) | (std::size_t{declared[1]} << 8) | declared[2]) != record.remaining()) { return; }
    record.take(version_bytes + random_bytes);
    record.take(record.byte());
    const auto ciphers = record.word();
    if (ciphers == 0 || ciphers % 2 != 0) { return; }
    record.take(ciphers);
    record.take(record.byte());
    if (record.failed()) { return; }
    if (record.empty()) { valid_ = true; return; }
    const auto extension_bytes = record.take(record.word());
    if (record.failed() || !record.empty()) { return; }

    bool seen_alpn = false, seen_name = false;
    Cursor extensions{extension_bytes};
    while (!extensions.empty()) {
      const auto kind = extensions.word();
      const auto body = extensions.take(extensions.word());
      if (extensions.failed()) { return; }
      if (kind == alpn_extension) {
        if (seen_alpn) { return; }
        seen_alpn = true;
        if (!protocols(body)) { return; }
      } else if (kind == 0) {
        if (seen_name || !serverName(body)) { return; }
        seen_name = true;
      } else if (kind == 0xfe0d) {
        encrypted_ = true;
      }
    }
    valid_ = true;
  }

  bool tls() const noexcept { return tls_; }
  bool valid() const noexcept { return valid_; }
  bool encrypted() const noexcept { return encrypted_; }
  std::string_view serverName() const noexcept { return server_name_.view(); }

  std::span<const std::uint8_t> encoded() const noexcept { return protocols_; }

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

  Read incomplete(std::size_t count) const noexcept { return count == bytes_.size() ? Read::complete : Read::pending; }

  bool serverName(std::span<const std::uint8_t> extension) noexcept {
    Cursor names{extension};
    const auto length = names.word();
    if (names.failed() || length != names.remaining()) { return false; }
    while (!names.empty()) {
      const auto type = names.byte();
      const auto value = names.take(names.word());
      if (names.failed()) { return false; }
      if (type == 0) {
        const std::string_view host{reinterpret_cast<const char *>(value.data()), value.size()};
        if (!server_name_.view().empty() || !ProxyHostname::validTarget(host)) { return false; }
        server_name_.assign(host);
      }
    }
    return true;
  }

  bool protocols(std::span<const std::uint8_t> extension) noexcept {
    Cursor names{extension};
    const auto declared = names.word();
    if (names.failed() || declared == 0 || declared != names.remaining()) { return false; }
    while (!names.empty()) {
      const auto length = names.byte();
      names.take(length);
      if (names.failed() || length == 0) { return false; }
    }
    protocols_ = extension.subspan(2);
    return true;
  }

  static constexpr std::uint8_t handshake_record = 22;
  static constexpr std::uint8_t client_hello = 1;
  static constexpr std::uint16_t alpn_extension = 16;
  static constexpr std::size_t record_header_bytes = 5;
  static constexpr std::size_t maximum_record_bytes = 16 * 1024;
  static constexpr std::size_t handshake_length_bytes = 3;
  static constexpr std::size_t version_bytes = 2;
  static constexpr std::size_t random_bytes = 32;
  static constexpr std::size_t maximum_hello_bytes = 64 * 1024;
  std::array<std::uint8_t, maximum_hello_bytes> bytes_;
  FixedText<ProxyHostname::maximum_bytes> server_name_;
  bool tls_ = false;
  bool valid_ = false;
  bool encrypted_ = false;
  std::span<const std::uint8_t> protocols_;
};

}
