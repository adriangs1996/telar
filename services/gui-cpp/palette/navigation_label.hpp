#pragma once

#include "core/unicode_scalar.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <cstddef>
#include <string_view>

namespace telar::gui {

class NavigationLabel {
public:
  static constexpr std::size_t capacity = 160;
  static constexpr std::string_view detail_separator = "  ";
  static constexpr std::string_view tab_prefix = "tab ";

  void append(std::string_view text) {
    const auto available = capacity - text_.view().size();
    text_.append(text.substr(0, std::min(available, text.size())));
  }

  void appendDetail(std::string_view detail) {
    if (!detail.empty()) {
      append(detail_separator);
      append(detail);
    }
  }

  [[nodiscard]] std::string_view view() const noexcept {
    auto text = text_.view();
    if (text.size() != capacity) {
      return text;
    }

    auto boundary = text.size();
    constexpr unsigned leading_mask = ~Utf8Scalar::continuation_mask;
    while (boundary != 0 && (static_cast<unsigned char>(text[boundary - 1]) & leading_mask) == Utf8Scalar::continuation_prefix) {
      --boundary;
    }

    if (boundary == 0) {
      return text;
    }

    const auto last_start = boundary - 1;
    const auto sequence = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text[last_start]));
    const auto complete = sequence <= Utf8Scalar::leading_masks.size() && text.size() - last_start >= sequence;

    if (!complete) {
      text.remove_suffix(text.size() - last_start);
    }

    return text;
  }

private:
  BoundedText<capacity> text_;
};

}
