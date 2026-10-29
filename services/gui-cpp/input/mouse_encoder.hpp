#pragma once

#include <algorithm>
#include <array>
#include <charconv>
#include <limits>
#include <string_view>

namespace telar::gui {

class MouseEncoder {
public:
  static constexpr unsigned wheel_up = 64;
  static constexpr unsigned wheel_down = 65;

  std::string_view encode(unsigned button, unsigned x, unsigned y, bool released, bool sgr) noexcept {
    used_ = 0;
    if (sgr) {
      append("\x1b[<");
      number(button);
      append(";");
      number(x);
      append(";");
      number(y);
      character(released ? 'm' : 'M');
    } else {
      constexpr unsigned offset = 32;
      constexpr unsigned maximum_coordinate = 223;
      constexpr unsigned released_button = 3;
      if (x > maximum_coordinate || y > maximum_coordinate) {
        return {};
      }

      append("\x1b[M");
      character(static_cast<char>((released ? released_button : button) + offset));
      character(static_cast<char>(x + offset));
      character(static_cast<char>(y + offset));
    }

    return {buffer_.data(), used_};
  }

private:
  static constexpr std::size_t integer_digits = std::numeric_limits<unsigned>::digits10 + 1;
  static constexpr std::size_t numeric_fields = 3;
  static constexpr std::size_t packet_syntax_bytes = 8;

  void append(std::string_view text) noexcept {
    std::ranges::copy(text, buffer_.begin() + used_);
    used_ += text.size();
  }

  void character(char value) noexcept {
    buffer_[used_++] = value;
  }

  void number(unsigned value) noexcept {
    const auto result = std::to_chars(buffer_.data() + used_, buffer_.data() + buffer_.size(), value);
    used_ = static_cast<std::size_t>(result.ptr - buffer_.data());
  }

  std::array<char, (integer_digits * numeric_fields) + packet_syntax_bytes> buffer_{};
  std::size_t used_ = 0;
};

}
