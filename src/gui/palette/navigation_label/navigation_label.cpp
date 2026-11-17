module telar.gui.palette.navigation_label;

import telar.gui.foundation.core;

namespace telar::gui {

  void NavigationLabel::append(std::string_view text) {
    const auto available = capacity - text_.view().size();

    text_.append(text.substr(0, std::min(available, text.size())));
  }

  void NavigationLabel::appendDetail(std::string_view detail) {
    if (!detail.empty()) {
      append(detail_separator);
      append(detail);
    }
  }

  std::string_view NavigationLabel::view() const noexcept {
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

}
