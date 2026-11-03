#pragma once

#include <optional>
#include <string_view>

namespace telar::runtime {

class TextFields {
public:
  explicit TextFields(std::string_view text, std::string_view delimiter) noexcept
      : remaining_(text), delimiter_(delimiter) {}

  std::optional<std::string_view> next() noexcept {
    if (finished_) {
      return std::nullopt;
    }
    const auto boundary = remaining_.find(delimiter_);
    const auto field = remaining_.substr(0, boundary);
    if (boundary == std::string_view::npos) {
      finished_ = true;
    } else {
      remaining_.remove_prefix(boundary + delimiter_.size());
    }
    return field;
  }

private:
  std::string_view remaining_;
  std::string_view delimiter_;
  bool finished_ = false;
};

inline std::string_view trimText(std::string_view text, std::string_view characters) noexcept {
  const auto start = text.find_first_not_of(characters);
  if (start == std::string_view::npos) {
    return {};
  }
  return text.substr(start, text.find_last_not_of(characters) - start + 1);
}

}
