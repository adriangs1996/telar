module telar.gui.input.configuration;

import std;
import telar.wire.vocabulary;

namespace telar::gui {

  void InputConfiguration::setPrefix(KeyChord key) noexcept {
    prefix = key;
    for (auto& binding : std::span{configured}.first(length)) {
      if (binding.prefixed) {
        binding.keys[0] = key;
      }
    }
  }

  BindingMap<BindingAction> InputConfiguration::compile() const {
    auto resolved = configured;
    auto count = length;
    const auto explicit_bindings = std::span{configured}.first(length);

    for (const auto& original : default_bindings) {
      const Binding binding{.keys = {prefix, original.suffix}, .length = 2, .action = original.action, .prefixed = true};
      const bool overridden = std::ranges::any_of(explicit_bindings, [&](const auto& configured) {
        return configured.conflictsWith(binding);
      });
      if (!overridden && count < resolved.size()) {
        resolved[count++] = binding;
      }
    }

    return BindingMap<BindingAction>{std::span{resolved}.first(count)};
  }

  void HistoryText::validate(std::string_view text, bool bracketed_paste) {
    if (text.empty() || text.size() > maximum_bytes) {
      throw EncodingError{"Command is empty or exceeds its input capacity"};
    }

    validateUtf8(text);
    for (std::size_t index = 0; index < text.size(); ++index) {
      const auto byte = static_cast<Byte>(text[index]);
      if (byte == '\n' || byte == '\t') {
        if (!bracketed_paste) {
          throw EncodingError{"Multiline/tab paste requires shell bracketed-paste support"};
        }

        continue;
      }

      if (isControl(text, index)) {
        throw EncodingError{"Command contains terminal controls; cannot paste"};
      }
    }
  }

  bool HistoryText::isControl(std::string_view text, std::size_t index) noexcept {
    constexpr Byte first_printable = 0x20;
    constexpr Byte delete_control = 0x7f;
    constexpr Byte extended_control_lead = 0xc2;
    constexpr Byte first_extended_control = 0x80;
    constexpr Byte last_extended_control = 0x9f;
    const auto byte = static_cast<Byte>(text[index]);
    if (byte < first_printable || byte == delete_control) {
      return true;
    }

    if (byte != extended_control_lead || index + 1 == text.size()) {
      return false;
    }

    const auto next = static_cast<Byte>(text[index + 1]);

    return next >= first_extended_control && next <= last_extended_control;
  }

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
