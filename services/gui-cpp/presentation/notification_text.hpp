#pragma once

#include "memory/fixed_text.hpp"
#include "text/bounded_text.hpp"
#include "text/grapheme_cursor.hpp"
#include "text/text_fit.hpp"
#include "text/utf8.hpp"
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class NotificationText {
public:
  static constexpr std::size_t maximum_lines = 3;

  [[nodiscard]] std::size_t count() const noexcept {
    return count_;
  }

  [[nodiscard]] std::string_view line(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"InvalidNotificationLine"};
    }

    return owned_tail_ && index + 1 == count_ ? tail_.view() : lines_[index];
  }

  template <LabelMeasure Measure>
  void wrap(std::string_view text, float width, Measure &measure) {
    *this = {};
    auto remaining = trimStart(text);
    const auto last = remaining.find_last_not_of(whitespace);
    remaining = last == std::string_view::npos ? std::string_view{} : remaining.substr(0, last + 1);
    while (!remaining.empty() && count_ < maximum_lines) {
      const auto newline = remaining.find_first_of("\r\n");
      const auto paragraph = remaining.substr(0, newline);
      if (count_ + 1 == maximum_lines) {
        fitTail(paragraph, newline != std::string_view::npos, width, measure);
        break;
      }

      const auto end = measure(paragraph) > width ? wrapEnd(paragraph, width, measure) : paragraph.size();
      if (end == 0) {
        break;
      }

      const auto prefix = paragraph.substr(0, end);
      const auto last_word = prefix.find_last_not_of(" \t");
      lines_[count_++] = last_word == std::string_view::npos ? std::string_view{} : prefix.substr(0, last_word + 1);
      remaining = trimStart(remaining.substr(end));
    }
  }

private:
  static constexpr std::string_view whitespace = " \t\r\n";

  [[nodiscard]] static std::string_view trimStart(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(whitespace);
    text.remove_prefix(first == std::string_view::npos ? text.size() : first);

    return text;
  }

  template <LabelMeasure Measure>
  [[nodiscard]] static std::size_t wrapEnd(std::string_view paragraph, float width, Measure &measure) {
    GraphemeCursor cursor{paragraph};
    std::size_t end = 0;
    std::size_t word_end = 0;
    while (const auto cluster = cursor.next()) {
      const auto candidate = end + cluster->size();
      if (measure(paragraph.substr(0, candidate)) > width) {
        break;
      }

      if (*cluster == " " || *cluster == "\t") {
        word_end = end;
      }

      end = candidate;
    }

    return word_end > 0 ? word_end : end;
  }

  template <LabelMeasure Measure>
  void fitTail(std::string_view paragraph, bool following_paragraph, float width, Measure &measure) {
    BoundedText<TextFit::maximum_bytes> continuation;
    auto label = paragraph;
    if (following_paragraph) {
      continuation.append(runtime::utf8Prefix(paragraph, TextFit::maximum_bytes - TextFit::ellipsis.size()));
      continuation.append(TextFit::ellipsis);
      label = continuation.view();
    }

    TextFit::Buffer fitted_buffer;
    const auto fitted = TextFit::fit(label, width, measure, fitted_buffer);
    owned_tail_ = following_paragraph || fitted.data() == fitted_buffer.data();
    if (owned_tail_) {
      tail_.assign(fitted);
    } else {
      lines_[count_] = fitted;
    }

    ++count_;
  }

  std::array<std::string_view, maximum_lines> lines_{};
  runtime::FixedText<TextFit::maximum_bytes> tail_;
  std::size_t count_ = 0;
  bool owned_tail_ = false;
};

}
