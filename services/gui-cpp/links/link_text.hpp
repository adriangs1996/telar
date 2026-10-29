#pragma once

#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

enum class LinkScheme : std::uint8_t {
  file,
  http,
  https,
  external,
  path,
};

struct TextRange {
  std::size_t start = 0;
  std::size_t end = 0;

  [[nodiscard]] std::string_view view(std::string_view text) const {
    return text.substr(start, end - start);
  }

  bool operator==(const TextRange &) const = default;
};

struct LinkTextMatch {
  LinkScheme scheme = LinkScheme::external;
  TextRange extent;
  TextRange destination;
};

struct LinkText {
  static constexpr std::size_t maximum_uri_bytes = 4096;
  static constexpr std::size_t maximum_label_bytes = 512;
  static constexpr std::size_t markdown_delimiter_bytes = 4;
  static constexpr std::size_t maximum_span_bytes = maximum_uri_bytes + maximum_label_bytes + markdown_delimiter_bytes;
  static constexpr unsigned first_non_ascii = 0x80;
  static constexpr unsigned delete_control = 0x7f;

  [[nodiscard]] static constexpr bool control(char byte) noexcept {
    return static_cast<unsigned char>(byte) < ' ' || static_cast<unsigned char>(byte) == delete_control;
  }

  [[nodiscard]] static constexpr bool digit(char byte) noexcept {
    return byte >= '0' && byte <= '9';
  }

  [[nodiscard]] static constexpr bool alphanumeric(char byte) noexcept {
    return digit(byte) || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }

  [[nodiscard]] static constexpr bool separator(char byte) noexcept {
    return control(byte) || byte == ' ' || std::string_view{"\"'<>`"}.contains(byte);
  }

  [[nodiscard]] static bool validUtf8(std::string_view text) noexcept {
    try {
      validateUtf8(text);

      return true;
    } catch (const EncodingError &) {
      return false;
    }
  }
};

}
