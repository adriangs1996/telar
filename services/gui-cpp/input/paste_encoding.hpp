#pragma once

#include "text/bounded_text.hpp"
#include <cstddef>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

struct PasteEncoding {
  static constexpr std::string_view begin = "\x1b[200~";
  static constexpr std::string_view end = "\x1b[201~";
  static constexpr std::size_t framing_bytes = begin.size() + end.size();

  template <std::size_t Capacity>
  [[nodiscard]] static BoundedText<Capacity + framing_bytes> encode(std::string_view text, bool bracketed) {
    if (text.size() > Capacity) {
      throw std::length_error{"Paste text exceeds its capacity"};
    }

    BoundedText<Capacity + framing_bytes> encoded;
    if (bracketed) {
      encoded.append(begin);
    }

    encoded.append(text);
    if (bracketed) {
      encoded.append(end);
    }

    return encoded;
  }
};

}
