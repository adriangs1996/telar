#pragma once

#include "grapheme_cursor.hpp"
#include "label_text.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

template <typename Measure>
concept LabelMeasure = requires(Measure &measure, std::string_view text) {
  { measure(text) } -> std::convertible_to<float>;
};

struct TextFit {
  static constexpr std::size_t maximum_bytes = label_text_capacity;
  static constexpr std::string_view ellipsis = "…";
  using Buffer = std::array<char, maximum_bytes>;

  template <LabelMeasure Measure>
  [[nodiscard]] static std::string_view fit(std::string_view text, float width, Measure &measure, Buffer &buffer) {
    if (!std::isfinite(width)) {
      throw std::invalid_argument{"InvalidTextFitWidth"};
    }

    const auto full = measureText(measure, text);
    if (full <= width) {
      return text;
    }

    const auto tail = measureText(measure, ellipsis);
    if (tail > width) {
      return {};
    }

    const auto prefixes = collectPrefixes(text);
    const auto room = width - tail;
    const auto estimate = static_cast<std::size_t>(std::floor(static_cast<float>(prefixes.graphemes) * room / full));
    auto keep = std::min(estimate, prefixes.stored);
    while (keep > 0 && measureText(measure, text.substr(0, prefixes.bytes[keep])) > room) {
      --keep;
    }

    const auto prefix = text.substr(0, prefixes.bytes[keep]);
    auto *output = std::ranges::copy(prefix, buffer.begin()).out;
    output = std::ranges::copy(ellipsis, output).out;

    return {buffer.data(), static_cast<std::size_t>(output - buffer.begin())};
  }

private:
  template <LabelMeasure Measure>
  [[nodiscard]] static float measureText(Measure &measure, std::string_view text) {
    const auto width = static_cast<float>(measure(text));
    if (!std::isfinite(width) || width < 0) {
      throw std::invalid_argument{"InvalidTextFitMeasurement"};
    }

    return width;
  }

  struct Prefixes {
    std::array<std::size_t, maximum_bytes> bytes{};
    std::size_t graphemes = 0;
    std::size_t stored = 0;
  };

  [[nodiscard]] static Prefixes collectPrefixes(std::string_view text) {
    GraphemeCursor cursor{text};
    Prefixes result;
    std::size_t bytes = 0;
    while (const auto cluster = cursor.next()) {
      ++result.graphemes;
      bytes += cluster->size();
      if (bytes <= maximum_bytes - ellipsis.size()) {
        result.bytes[++result.stored] = bytes;
      }
    }

    return result;
  }
};

}
