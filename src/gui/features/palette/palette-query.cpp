module telar.gui.features.palette;

import std;

import telar.base.history;
import telar.gui.foundation.core;

namespace telar::gui::features::palette {

  namespace {

    bool sameLetter(char left, char right) noexcept {
      return runtime::asciiLower(static_cast<unsigned char>(left)) == runtime::asciiLower(static_cast<unsigned char>(right));
    }

    bool asciiAlphanumeric(unsigned char byte) noexcept {
      return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
    }

    // What matching the label's byte at `index` adds: a word start, after an ASCII separator or a
    // lowercase-to-uppercase step, is worth more than a byte inside a word.
    std::int32_t boundaryBonus(std::string_view label, std::size_t index) noexcept {
      if (index == 0) {
        return PaletteScore::boundary_bonus;
      }

      constexpr unsigned char first_non_ascii = 0x80;
      const auto previous = static_cast<unsigned char>(label[index - 1]);
      const auto current = static_cast<unsigned char>(label[index]);

      if (previous < first_non_ascii && !asciiAlphanumeric(previous)) {
        return PaletteScore::boundary_bonus;
      }

      if (previous >= 'a' && previous <= 'z' && current >= 'A' && current <= 'Z') {
        return PaletteScore::camel_bonus;
      }

      return 0;
    }

    // The bytes of the label from the first to the last it matches of the query, as tight as the
    // query allows.
    struct Window {
      std::size_t start = 0;
      std::size_t end = 0;
    };

    ds::Option<Window> tightestWindow(std::string_view label, std::string_view query) noexcept {
      // The first place where the whole query fits ends the window.
      std::size_t matched = 0;
      std::size_t end = 0;

      for (std::size_t index = 0; index < label.size() && matched < query.size(); ++index) {
        if (sameLetter(label[index], query[matched])) {
          end = index;
          ++matched;
        }
      }

      if (matched != query.size()) {
        return ds::none;
      }

      // Walking back from there finds the latest start that still fits: the tightest window.
      auto start = end;
      auto remaining = query.size();

      for (auto index = end + 1; index-- > 0 && remaining > 0;) {
        if (sameLetter(label[index], query[remaining - 1])) {
          start = index;
          --remaining;
        }
      }

      return Window{.start = start, .end = end};
    }

  }

  ds::Option<std::uint32_t> PaletteScore::of(std::string_view label, std::string_view query) noexcept {
    if (query.empty()) {
      return 1;
    }

    const auto window = tightestWindow(label, query);
    if (!window) {
      return ds::none;
    }

    std::int32_t score = 0;
    std::int32_t run_bonus = 0;
    std::size_t next = 0;
    bool consecutive = false;
    bool in_gap = false;

    for (auto index = window->start; index <= window->end; ++index) {
      if (next == query.size() || !sameLetter(label[index], query[next])) {
        score -= in_gap ? gap_extension : gap_start;
        in_gap = true;
        consecutive = false;
        continue;
      }

      auto bonus = boundaryBonus(label, index);

      if (!consecutive) {
        run_bonus = bonus;
      } else {
        if (bonus >= boundary_bonus && bonus > run_bonus) {
          run_bonus = bonus;
        }

        bonus = std::max({bonus, run_bonus, consecutive_bonus});
      }

      score += match + (next == 0 ? bonus * first_multiplier : bonus);
      ++next;
      consecutive = true;
      in_gap = false;
    }

    return static_cast<std::uint32_t>(std::max<std::int64_t>(2, static_cast<std::int64_t>(base) + score));
  }

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
