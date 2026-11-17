module telar.gui.features.notifications;

import std;
import telar.tbc;
import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

namespace telar::gui::features::notifications {

  float NotificationText::Measured::operator()(std::string_view text) const {
    return call(target, text);
  }

  void NotificationText::wrapMeasured(tbc::view<std::string_view, tbc::lt::a> text, float width, Measured measure) {
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

  std::size_t NotificationText::wrapEnd(std::string_view paragraph, float width, Measured& measure) {
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

  void NotificationText::fitTail(tbc::view<std::string_view, tbc::lt::a> paragraph, bool following_paragraph, float width, Measured& measure) {
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
      // Unless the fit shortens the label into its buffer, it keeps the whole paragraph or nothing.
      lines_[count_] = fitted.empty() ? std::string_view{} : paragraph;
    }

    ++count_;
  }

  std::size_t NotificationText::count() const noexcept {
    return count_;
  }

  std::string_view NotificationText::line(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"InvalidNotificationLine"};
    }

    return owned_tail_ && index + 1 == count_ ? tail_.view() : lines_[index];
  }

  std::string_view NotificationText::trimStart(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(whitespace);

    text.remove_prefix(first == std::string_view::npos ? text.size() : first);

    return text;
  }

}
