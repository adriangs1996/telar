#pragma once

#include "core/unicode_scalar.hpp"
#include "font_coverage.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui::fonts {

class FontQuery {
public:
  static constexpr std::size_t maximum_bytes = 64;

  [[nodiscard]] static std::optional<FontQuery> create(std::string_view text) {
    if (text.size() > maximum_bytes) {
      return std::nullopt;
    }

    FontQuery query;
    std::ranges::copy(text, query.text_.begin());
    query.text_length_ = static_cast<std::uint8_t>(text.size());
    while (!text.empty()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text.front()));
      if (length == 0 || length > Utf8Scalar::leading_masks.size() || length > text.size()) {
        throw std::invalid_argument{"InvalidFontQueryUtf8"};
      }

      const auto scalar = text.substr(0, length);
      if (!FontCoverage::isSelectorOrJoiner(Utf8Scalar::decode(scalar))) {
        std::ranges::copy(scalar, query.codepoints_.begin() + query.query_length_);
        query.query_length_ = static_cast<std::uint8_t>(query.query_length_ + length);
      }

      text.remove_prefix(length);
    }

    return query.query_length_ == 0 ? std::nullopt : std::optional{query};
  }

  [[nodiscard]] std::string_view text() const noexcept {
    return {text_.data(), text_length_};
  }

  [[nodiscard]] const char *codepoints() const noexcept {
    return codepoints_.data();
  }

private:
  std::array<char, maximum_bytes> text_{};
  std::array<char, maximum_bytes + 1> codepoints_{};
  std::uint8_t text_length_ = 0;
  std::uint8_t query_length_ = 0;
};

}
