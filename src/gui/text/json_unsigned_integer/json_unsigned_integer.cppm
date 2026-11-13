module;
#include <cstdlib>
#include <new>

#include <cstdint>

#include <cstddef>

#include <cstring>



#include <ghostty/vt/unicode.h>
#include <cmath>
#include "tbc/view.hpp"

export module telar.gui.text.json_unsigned_integer;

import std;

export import telar.base.text;
export import telar.machines;


export import telar.gui.text.bounded_editor;
import telar.base.diagnostics;
import telar.base.memory;
import telar.gui.core.primitives;

// Interface: text/bounded_text.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
using telar::runtime::machines::BoundedText;
}

// Interface: text/label_text.cppm
export {
namespace telar::gui {

inline constexpr std::size_t label_text_capacity = 256;
using LabelText = BoundedText<label_text_capacity>;

}
}

// Interface: text/text_fit.cppm
export {
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
  // The fitted text is the text itself or the prefix written into the buffer, region `a`.
  [[nodiscard]] inline static tbc::view<std::string_view, tbc::lt::a> fit(tbc::view<std::string_view, tbc::lt::a> text, float width, Measure &measure, tbc::view<Buffer &, tbc::lt::a> buffer) {
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
  [[nodiscard]] inline static float measureText(Measure &measure, std::string_view text) {
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

  [[nodiscard]] inline static Prefixes collectPrefixes(std::string_view text) {
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
}
