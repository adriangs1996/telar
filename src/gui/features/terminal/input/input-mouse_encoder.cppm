// The bytes a mouse report or a wheel step is to the program: SGR or the legacy X10 packet.
export module telar.gui.features.terminal.input:mouse_encoder;

import std;

// Interface: input/mouse_encoder.cppm
export {
  namespace telar::gui::features::terminal::input {

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
