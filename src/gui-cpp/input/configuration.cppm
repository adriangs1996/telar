module;
#include <cstring>
#include <cstdio>

#include <cstdint>
#include <cstddef>


export module telar.gui.input.configuration;

import std;

export import telar.gui.input.copy_pointer;
export import telar.gui.input.key_encoder;

export import telar.gui.config.gui_query;
import telar.client.protocol;

// Interface: input/configuration.cppm
export {
namespace telar::gui {

struct InputConfiguration {
  using Binding = KeyBinding<BindingAction>;

  KeyChord prefix{.key = KeyChord::Key::character, .character = 'b', .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
  std::uint64_t sequence_timeout_ns = BindingLimits::sequence_timeout_ns;
  std::array<Binding, BindingLimits::bindings> configured{};
  std::size_t length = 0;
  std::size_t dropped = 0;

  inline void setPrefix(KeyChord key) noexcept {
    prefix = key;
    for (auto &binding : std::span{configured}.first(length)) {
      if (binding.prefixed) {
        binding.keys[0] = key;
      }
    }
  }

  [[nodiscard]] inline BindingMap<BindingAction> compile() const {
    auto resolved = configured;
    auto count = length;
    const auto explicit_bindings = std::span{configured}.first(length);
    for (const auto &original : default_bindings) {
      const Binding binding{.keys = {prefix, original.suffix}, .length = 2, .action = original.action, .prefixed = true};
      const bool overridden = std::ranges::any_of(explicit_bindings, [&](const auto &configured) {
        return configured.conflictsWith(binding);
      });
      if (!overridden && count < resolved.size()) {
        resolved[count++] = binding;
      }
    }

    return BindingMap<BindingAction>{std::span{resolved}.first(count)};
  }
};

}
}

// Interface: input/history_text.cppm
export {
namespace telar::gui {

class HistoryText {
public:
  static constexpr std::size_t maximum_bytes = std::size_t{64} * 1024;

  inline static void validate(std::string_view text, bool bracketed_paste) {
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

private:
  inline static bool isControl(std::string_view text, std::size_t index) noexcept {
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
};

}
}

// Interface: input/mouse_encoder.cppm
export {
namespace telar::gui {

class MouseEncoder {
public:
  static constexpr unsigned wheel_up = 64;
  static constexpr unsigned wheel_down = 65;

  inline std::string_view encode(unsigned button, unsigned x, unsigned y, bool released, bool sgr) noexcept {
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

  inline void append(std::string_view text) noexcept {
    std::ranges::copy(text, buffer_.begin() + used_);
    used_ += text.size();
  }

  inline void character(char value) noexcept {
    buffer_[used_++] = value;
  }

  inline void number(unsigned value) noexcept {
    const auto result = std::to_chars(buffer_.data() + used_, buffer_.data() + buffer_.size(), value);
    used_ = static_cast<std::size_t>(result.ptr - buffer_.data());
  }

  std::array<char, (integer_digits * numeric_fields) + packet_syntax_bytes> buffer_{};
  std::size_t used_ = 0;
};

}
}
