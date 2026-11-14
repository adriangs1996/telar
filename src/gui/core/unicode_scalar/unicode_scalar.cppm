export module telar.gui.core.unicode_scalar;

import std;

// Interface: core/calendar_sample.cppm
export {
  namespace telar::gui {

    struct CalendarSample {
      std::int64_t now_ms = 0;
      std::int16_t utc_offset_min = 0;

      bool operator==(const CalendarSample&) const = default;
    };

  }
}

// Interface: core/cell_rectangle.cppm
export {
  namespace telar::gui {

    struct CellRectangle {
      std::uint16_t x = 0;
      std::uint16_t y = 0;
      std::uint16_t width = 0;
      std::uint16_t height = 0;

      [[nodiscard]] std::uint32_t right() const noexcept;
      [[nodiscard]] std::uint32_t bottom() const noexcept;
      [[nodiscard]] bool empty() const noexcept;
      [[nodiscard]] CellRectangle inner(std::uint16_t margin) const noexcept;
      [[nodiscard]] CellRectangle intersect(CellRectangle other) const noexcept;
      [[nodiscard]] CellRectangle row(std::uint16_t index) const noexcept;

      bool operator==(const CellRectangle&) const = default;
    };

  }
}

// Interface: core/monotonic_clock.cppm
export {
  namespace telar::gui {

    template <typename Clock>
    concept MonotonicClock = requires {
      { Clock::nowNanoseconds() } noexcept -> std::same_as<std::uint64_t>;
    };

  }
}

// Interface: core/smoothstep.cppm
export {
  namespace telar::gui {

    [[nodiscard]] constexpr float smoothstep(float position) noexcept {
      constexpr float quadratic_weight = 3;
      constexpr float cubic_weight = 2;

      return position * position * (quadratic_weight - (cubic_weight * position));
    }

  }
}

// Interface: core/unicode_scalar.cppm
export {
  namespace telar::gui {

    struct Utf8Scalar {
      static constexpr std::uint32_t maximum_codepoint = 0x10ffff;
      static constexpr std::uint32_t first_surrogate = 0xd800;
      static constexpr std::uint32_t last_surrogate = 0xdfff;
      static constexpr unsigned continuation_bits = 6;
      static constexpr unsigned continuation_prefix = 0x80;
      static constexpr unsigned continuation_mask = 0x3f;
      static constexpr std::array<unsigned, 4> leading_prefixes{0, 0xc0, 0xe0, 0xf0};
      static constexpr std::array<unsigned, 4> leading_masks{0x7f, 0x1f, 0x0f, 0x07};
      static constexpr std::array<std::uint32_t, 4> minimum_codepoints{0, 0x80, 0x800, 0x10000};
      static constexpr std::array<std::uint32_t, 4> maximum_codepoints{0x7f, 0x7ff, 0xffff, maximum_codepoint};

      std::array<char, 4> bytes{};
      std::size_t length = 0;

      [[nodiscard]] static constexpr std::size_t sequenceLength(unsigned char leading) noexcept {
        return leading < continuation_prefix ? std::size_t{1} : static_cast<std::size_t>(std::countl_one(leading));
      }

      [[nodiscard]] std::string_view view() const noexcept;

      [[nodiscard]] static constexpr bool valid(std::uint32_t codepoint) noexcept {
        return codepoint <= maximum_codepoint && (codepoint < first_surrogate || codepoint > last_surrogate);
      }

      [[nodiscard]] static Utf8Scalar encode(std::uint32_t codepoint);
      [[nodiscard]] static std::uint32_t decode(std::string_view text);
      [[nodiscard]] static std::optional<std::uint32_t> tryDecode(std::string_view text) noexcept;

    private:
      enum class DecodeError : std::uint8_t {
        none,
        length,
        leading_byte,
        continuation_byte,
        scalar,
      };

      struct Decoded {
        std::uint32_t value = 0;
        DecodeError error = DecodeError::none;
      };

      [[nodiscard]] static Decoded read(std::string_view text) noexcept;
    };

  }
}

// Interface: core/view_version.cppm
export {
  namespace telar::gui {

    struct ViewVersion {
      std::uint64_t workspace = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t tabs = 0;
      std::uint64_t panes = 0;
      std::uint64_t host = 0;
      std::uint64_t configuration = 0;
      std::uint64_t viewport = 0;
      std::uint64_t machine = 0;

      bool operator==(const ViewVersion&) const = default;
    };

  }
}
