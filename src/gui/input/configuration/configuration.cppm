module;
#include <cstddef>
#include <cstdint>

export module telar.gui.input.configuration;

import std;

export import telar.gui.input.copy_pointer;
export import telar.gui.input.key_encoder;
import telar.wire.vocabulary;

// Interface: config/default_bindings.cppm
export {
#include "input/default_bindings.inc"
}

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

      void setPrefix(KeyChord key) noexcept;

      [[nodiscard]] BindingMap<BindingAction> compile() const;
    };

  }
}

// Interface: input/history_text.cppm
export {
  namespace telar::gui {

    class HistoryText {
    public:
      static constexpr std::size_t maximum_bytes = std::size_t{64} * 1024;

      static void validate(std::string_view text, bool bracketed_paste);

    private:
      static bool isControl(std::string_view text, std::size_t index) noexcept;
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

      std::string_view encode(unsigned button, unsigned x, unsigned y, bool released, bool sgr) noexcept;

    private:
      static constexpr std::size_t integer_digits = std::numeric_limits<unsigned>::digits10 + 1;
      static constexpr std::size_t numeric_fields = 3;
      static constexpr std::size_t packet_syntax_bytes = 8;

      void append(std::string_view text) noexcept;

      void character(char value) noexcept;

      void number(unsigned value) noexcept;

      std::array<char, (integer_digits * numeric_fields) + packet_syntax_bytes> buffer_{};
      std::size_t used_ = 0;
    };

  }
}
