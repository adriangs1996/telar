#pragma once

#include "../memory/erase_sensitive.hpp"
#include "../text/ascii.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <span>
#include <string_view>

namespace telar::runtime {

class ProxySecret {
public:
  static constexpr std::size_t byte_count = 32;
  static constexpr std::size_t hexadecimal_bytes = byte_count * 2;

  static ProxySecret generate() noexcept {
    ProxySecret secret;
    ::arc4random_buf(secret.bytes_.data(), secret.bytes_.size());
    return secret;
  }

  static std::optional<ProxySecret> fromHexadecimal(std::string_view text) noexcept {
    if (text.size() != hexadecimal_bytes) {
      return std::nullopt;
    }

    ProxySecret secret;
    for (std::size_t index = 0; index < byte_count; ++index) {
      const auto high = digit(text[index * 2]);
      const auto low = digit(text[index * 2 + 1]);
      if (!high || !low) {
        return std::nullopt;
      }
      secret.bytes_[index] = static_cast<std::uint8_t>((*high << 4) | *low);
    }
    return secret;
  }

  ~ProxySecret() {
    eraseSensitive(bytes_.data(), bytes_.size());
  }

  ProxySecret(const ProxySecret &) = default;
  ProxySecret &operator=(const ProxySecret &) = default;

  bool matches(const ProxySecret &other) const noexcept {
    volatile unsigned difference = 0;
    for (std::size_t index = 0; index < byte_count; ++index) {
      difference = difference | (bytes_[index] ^ other.bytes_[index]);
    }
    return difference == 0;
  }

  std::optional<std::string_view> formatHexadecimal(std::span<char> destination) const noexcept {
    if (destination.size() < hexadecimal_bytes) {
      return std::nullopt;
    }

    for (std::size_t index = 0; index < byte_count; ++index) {
      destination[index * 2] = hexadecimal[bytes_[index] >> 4];
      destination[index * 2 + 1] = hexadecimal[bytes_[index] & 15];
    }
    return std::string_view{destination.data(), hexadecimal_bytes};
  }

  std::optional<std::string_view> formatUrl(std::span<char> destination, std::uint16_t port) const noexcept {
    constexpr std::string_view prefix = "http://telar:";
    constexpr std::string_view address = "@127.0.0.1:";
    constexpr std::size_t port_digits = 5;
    if (destination.size() < prefix.size() + hexadecimal_bytes + address.size() + port_digits) {
      return std::nullopt;
    }

    auto *end = std::copy(prefix.begin(), prefix.end(), destination.data());
    formatHexadecimal({end, hexadecimal_bytes});
    end += hexadecimal_bytes;
    end = std::copy(address.begin(), address.end(), end);
    end = std::to_chars(end, destination.data() + destination.size(), port).ptr;
    return std::string_view{destination.data(), static_cast<std::size_t>(end - destination.data())};
  }

private:
  ProxySecret() noexcept {}

  static std::optional<unsigned> digit(char character) noexcept {
    const auto position = hexadecimal.find(asciiLower(character));
    return position == std::string_view::npos ? std::nullopt : std::optional{static_cast<unsigned>(position)};
  }

  static constexpr std::string_view hexadecimal = "0123456789abcdef";
  std::array<std::uint8_t, byte_count> bytes_;
};

}
