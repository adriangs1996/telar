export module telar.gui.input.configuration;

import std;

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
