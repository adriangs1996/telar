module telar.gui.input.configuration;

import std;

namespace telar::gui {

  std::string_view MouseEncoder::encode(unsigned button, unsigned x, unsigned y, bool released, bool sgr) noexcept {
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

  void MouseEncoder::append(std::string_view text) noexcept {
    std::ranges::copy(text, buffer_.begin() + used_);
    used_ += text.size();
  }

  void MouseEncoder::character(char value) noexcept {
    buffer_[used_++] = value;
  }

  void MouseEncoder::number(unsigned value) noexcept {
    const auto result = std::to_chars(buffer_.data() + used_, buffer_.data() + buffer_.size(), value);

    used_ = static_cast<std::size_t>(result.ptr - buffer_.data());
  }

}
