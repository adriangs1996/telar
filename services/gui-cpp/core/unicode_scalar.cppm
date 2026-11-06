module;

#include <cstdint>


#include <algorithm>
#include <limits>


#include <concepts>


#include <array>
#include <bit>
#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string_view>

export module telar.gui.core.unicode_scalar;


// Interface: core/calendar_sample.cppm
export {
namespace telar::gui {

struct CalendarSample {
  std::int64_t now_ms = 0;
  std::int16_t utc_offset_min = 0;

  bool operator==(const CalendarSample &) const = default;
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

  [[nodiscard]] inline std::uint32_t right() const noexcept {
    return static_cast<std::uint32_t>(x) + width;
  }

  [[nodiscard]] inline std::uint32_t bottom() const noexcept {
    return static_cast<std::uint32_t>(y) + height;
  }

  [[nodiscard]] inline bool empty() const noexcept {
    return width == 0 || height == 0;
  }

  [[nodiscard]] inline CellRectangle inner(std::uint16_t margin) const noexcept {
    const auto shrink = static_cast<std::uint32_t>(margin) * 2;
    if (width <= shrink || height <= shrink) {
      return {.x = x, .y = y};
    }

    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();
    return {
        .x = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(x) + margin, static_cast<std::uint32_t>(maximum))),
        .y = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(y) + margin, static_cast<std::uint32_t>(maximum))),
        .width = static_cast<std::uint16_t>(width - shrink),
        .height = static_cast<std::uint16_t>(height - shrink),
    };
  }

  [[nodiscard]] inline CellRectangle intersect(CellRectangle other) const noexcept {
    const auto left = std::max(x, other.x);
    const auto top = std::max(y, other.y);
    const auto end = std::max<std::uint32_t>(left, std::min(right(), other.right()));
    const auto lower = std::max<std::uint32_t>(top, std::min(bottom(), other.bottom()));

    return {.x = left, .y = top, .width = static_cast<std::uint16_t>(end - left), .height = static_cast<std::uint16_t>(lower - top)};
  }

  [[nodiscard]] inline CellRectangle row(std::uint16_t index) const noexcept {
    if (index >= height) {
      return {.x = x, .y = y};
    }

    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();

    return {.x = x, .y = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(y) + index, static_cast<std::uint32_t>(maximum))), .width = width, .height = 1};
  }

  bool operator==(const CellRectangle &) const = default;
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

  [[nodiscard]] inline std::string_view view() const noexcept {
    return {bytes.data(), length};
  }

  [[nodiscard]] static constexpr bool valid(std::uint32_t codepoint) noexcept {
    return codepoint <= maximum_codepoint && (codepoint < first_surrogate || codepoint > last_surrogate);
  }

  [[nodiscard]] inline static Utf8Scalar encode(std::uint32_t codepoint) {
    if (!valid(codepoint)) {
      throw std::invalid_argument{"Invalid Unicode scalar"};
    }

    Utf8Scalar result;
    while (codepoint > maximum_codepoints[result.length]) {
      ++result.length;
    }

    const auto continuation_count = result.length;
    result.bytes[0] = static_cast<char>(leading_prefixes[continuation_count] | (codepoint >> (continuation_bits * continuation_count)));
    for (std::size_t index = 0; index < continuation_count; ++index) {
      const auto shift = continuation_bits * (continuation_count - index - 1);
      result.bytes[index + 1] = static_cast<char>(continuation_prefix | ((codepoint >> shift) & continuation_mask));
    }

    ++result.length;

    return result;
  }

  [[nodiscard]] inline static std::uint32_t decode(std::string_view text) {
    const auto decoded = read(text);
    switch (decoded.error) {
    case DecodeError::none:
      return decoded.value;
    case DecodeError::length:
      throw std::invalid_argument{"Expected one UTF-8 scalar"};
    case DecodeError::leading_byte:
      throw std::invalid_argument{"Invalid UTF-8 leading byte"};
    case DecodeError::continuation_byte:
      throw std::invalid_argument{"Invalid UTF-8 continuation byte"};
    case DecodeError::scalar:
      throw std::invalid_argument{"Invalid or overlong UTF-8 scalar"};
    }

    throw std::invalid_argument{"Invalid Unicode decoding state"};
  }

  [[nodiscard]] inline static std::optional<std::uint32_t> tryDecode(std::string_view text) noexcept {
    const auto decoded = read(text);
    if (decoded.error != DecodeError::none) {
      return std::nullopt;
    }

    return decoded.value;
  }

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

  [[nodiscard]] inline static Decoded read(std::string_view text) noexcept {
    if (text.empty() || text.size() > leading_masks.size()) {
      return {.error = DecodeError::length};
    }

    const auto length = text.size();
    const auto first = static_cast<unsigned char>(text.front());
    const auto prefix_mask = ~leading_masks[length - 1] & std::uint8_t{0xff};
    if ((first & prefix_mask) != leading_prefixes[length - 1]) {
      return {.error = DecodeError::leading_byte};
    }

    auto codepoint = static_cast<std::uint32_t>(first & leading_masks[length - 1]);
    auto continuations = text;
    continuations.remove_prefix(1);
    for (const auto byte : continuations) {
      const auto continuation = static_cast<unsigned char>(byte);
      constexpr unsigned prefix_mask = 0xc0;
      if ((continuation & prefix_mask) != continuation_prefix) {
        return {.error = DecodeError::continuation_byte};
      }

      codepoint = (codepoint << continuation_bits) | (continuation & continuation_mask);
    }

    if (!valid(codepoint) || codepoint < minimum_codepoints[length - 1]) {
      return {.error = DecodeError::scalar};
    }

    return {.value = codepoint};
  }
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

  bool operator==(const ViewVersion &) const = default;
};

}
}
