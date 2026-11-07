module;
#include <cstdlib>
#include <new>

#include <cstdint>

#include <cstddef>

#include <cstring>



#include <ghostty/vt/unicode.h>
#include <cmath>

export module telar.gui.text.json_unsigned_integer;

import std;

export import telar.base.text;


export import telar.gui.text.bounded_editor;
import telar.base.diagnostics;
import telar.base.memory;
import telar.gui.core.primitives;

// Interface: text/number_radix.cppm
export {
namespace telar::gui {

enum class NumberRadix : std::uint8_t {
  decimal = 10,
  hexadecimal = 16,
};

}
}

// Interface: text/binary_fraction.cppm
export {
namespace telar::gui {

template <std::size_t MaximumExponent>
class BinaryFraction {
public:
  inline explicit BinaryFraction(std::size_t exponent, NumberRadix radix = NumberRadix::decimal) {
    if (exponent == 0 || exponent > MaximumExponent) {
      throw std::out_of_range{"Binary fraction exponent exceeds capacity"};
    }

    if (radix == NumberRadix::hexadecimal) {
      length_ = (exponent + hexadecimal_bits - 1) / hexadecimal_bits;
      const auto trailing_bits = exponent % hexadecimal_bits;
      digits_[length_ - 1] = static_cast<std::uint8_t>(trailing_bits == 0 ? 1 : 1U << (hexadecimal_bits - trailing_bits));

      return;
    }

    if (radix != NumberRadix::decimal) {
      throw std::invalid_argument{"Unsupported binary fraction radix"};
    }

    length_ = exponent;
    deriveDecimal(exponent);
  }

  [[nodiscard]] inline unsigned digit(std::size_t position) const noexcept {
    return position < length_ ? digits_[position] : 0;
  }

  [[nodiscard]] inline unsigned complementDigit(std::size_t position, NumberRadix radix) const noexcept {
    if (position >= length_) {
      return 0;
    }

    return static_cast<unsigned>(radix) - digit(position) - static_cast<unsigned>(position + 1 < length_);
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return length_;
  }

private:
  static constexpr unsigned decimal_radix = 10;
  static constexpr unsigned hexadecimal_bits = 4;
  static constexpr unsigned decimal_limb_digits = 9;
  static constexpr std::uint64_t decimal_limb_base = 1'000'000'000;
  static constexpr std::uint64_t half_decimal_radix = decimal_radix / 2;
  static constexpr std::size_t limb_capacity = ((MaximumExponent + decimal_limb_digits - 1) / decimal_limb_digits) + 1;

  inline void deriveDecimal(std::size_t exponent) {
    std::array<std::uint32_t, limb_capacity> limbs{};
    limbs.front() = 1;
    std::size_t count = 1;
    for (std::size_t power = 0; power < exponent; ++power) {
      std::uint64_t carry = 0;
      for (auto &limb : std::span{limbs}.first(count)) {
        const auto product = (static_cast<std::uint64_t>(limb) * half_decimal_radix) + carry;
        limb = static_cast<std::uint32_t>(product % decimal_limb_base);
        carry = product / decimal_limb_base;
      }

      if (carry != 0) {
        limbs[count++] = static_cast<std::uint32_t>(carry);
      }
    }

    auto position = exponent;
    for (auto limb : std::span{limbs}.first(count)) {
      for (unsigned digit = 0; digit < decimal_limb_digits && position != 0; ++digit) {
        digits_[--position] = static_cast<std::uint8_t>(limb % decimal_radix);
        limb /= decimal_radix;
      }
    }
  }

  std::array<std::uint8_t, MaximumExponent> digits_{};
  std::size_t length_ = 0;
};

}
}

// Interface: text/bounded_text.cppm
export {
namespace telar::gui {

template <std::size_t Capacity>
class BoundedText {
public:
  inline void append(std::string_view text) {
    if (text.size() > Capacity - length_) {
      throw std::length_error{"Text capacity exceeded"};
    }

    if (!text.empty()) {
      std::memmove(storage_.data() + length_, text.data(), text.size());
      length_ += text.size();
    }
  }

  template <std::unsigned_integral Number>
  inline void appendDecimal(Number number) {
    const auto result = std::to_chars(storage_.data() + length_, storage_.data() + Capacity, number);
    if (result.ec != std::errc{}) {
      throw std::length_error{"Text capacity exceeded"};
    }

    length_ = static_cast<std::size_t>(result.ptr - storage_.data());
  }

  inline void truncate(std::size_t length) {
    if (length > length_) {
      throw std::out_of_range{"Text truncation exceeds length"};
    }

    length_ = length;
  }

  [[nodiscard]] inline std::string_view view() const noexcept {
    return {storage_.data(), length_};
  }

private:
  std::array<char, Capacity> storage_{};
  std::size_t length_ = 0;
};

}
}

// Interface: text/radix_number.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class RadixNumber {
public:
  static constexpr unsigned decimal_radix = static_cast<unsigned>(NumberRadix::decimal);
  static constexpr unsigned hexadecimal_radix = static_cast<unsigned>(NumberRadix::hexadecimal);
  static constexpr unsigned hexadecimal_bits = 4;

  inline RadixNumber(Memory &memory, std::string_view text, bool floating_syntax)
      : digits_(AllocatorRef<char, Memory>{memory}) {
    if (text.starts_with('+') || text.starts_with('-')) {
      negative_ = text.front() == '-';
      text.remove_prefix(1);
    }

    if (text.empty()) {
      invalid();
    }

    if (floating_syntax && (text.starts_with("0x") || text.starts_with("0X"))) {
      radix_ = hexadecimal_radix;
      text.remove_prefix(hexadecimal_prefix_bytes);
    }

    const auto marker = floating_syntax ? text.find_first_of(radix_ == hexadecimal_radix ? "pP" : "eE") : std::string_view::npos;
    const auto mantissa = text.substr(0, marker);
    readMantissa(mantissa, floating_syntax);
    if (marker != std::string_view::npos) {
      applyExponent(exponent(text.substr(marker + 1), text.size()));
    }

    normalize();
  }

  [[nodiscard]] inline bool negative() const noexcept {
    return negative_;
  }

  [[nodiscard]] inline NumberRadix radix() const noexcept {
    return static_cast<NumberRadix>(radix_);
  }

  [[nodiscard]] inline bool zero() const noexcept {
    return digits_.empty();
  }

  [[nodiscard]] inline bool integral() const noexcept {
    return point_ >= static_cast<std::ptrdiff_t>(digits_.size());
  }

  [[nodiscard]] inline std::size_t fractionLeadingZeros() const noexcept {
    return point_ < 0 ? static_cast<std::size_t>(-point_) : 0;
  }

  [[nodiscard]] inline std::uint32_t integerPart(std::uint32_t maximum) const {
    std::uint32_t value = 0;
    for (std::ptrdiff_t position = 0; position < point_; ++position) {
      const auto digit = digitAt(position);
      if (digit > maximum || value > (maximum - digit) / radix_) {
        invalid();
      }

      value = (value * radix_) + digit;
    }

    return value;
  }

  template <typename Fraction>
  [[nodiscard]] inline int compareFraction(const Fraction &threshold, bool complement = false) const noexcept {
    const auto extent = std::max(static_cast<std::ptrdiff_t>(threshold.size()), static_cast<std::ptrdiff_t>(digits_.size()) - point_);
    for (std::ptrdiff_t position = 0; position < extent; ++position) {
      const auto actual = digitAt(point_ + position);
      const auto expected = complement ? threshold.complementDigit(static_cast<std::size_t>(position), radix()) : threshold.digit(static_cast<std::size_t>(position));
      if (actual != expected) {
        return actual < expected ? -1 : 1;
      }
    }

    return 0;
  }

private:
  static constexpr std::string_view digit_symbols = "0123456789abcdef";
  static constexpr std::size_t hexadecimal_prefix_bytes = 2;
  static constexpr std::ptrdiff_t minimum_exponent_budget = 20'000;

  [[noreturn]] static void invalid() {
    throw std::invalid_argument{"Invalid numeric text"};
  }

  [[nodiscard]] unsigned digitAt(std::ptrdiff_t position) const noexcept {
    return position < 0 || position >= static_cast<std::ptrdiff_t>(digits_.size()) ? 0 : static_cast<unsigned>(digit_symbols.find(digits_[static_cast<std::size_t>(position)]));
  }

  static bool validDigit(char byte, unsigned radix) noexcept {
    return digit_symbols.find(runtime::asciiLower(byte)) < radix;
  }

  void readMantissa(std::string_view text, bool floating_syntax) {
    bool point_seen = false;
    for (std::size_t position = 0; position < text.size(); ++position) {
      const auto byte = text[position];
      if (byte == '.') {
        if (!floating_syntax || point_seen) {
          invalid();
        }

        point_seen = true;

        continue;
      }

      if (byte == '_') {
        if (position == 0 || position + 1 == text.size() || (floating_syntax && (!validDigit(text[position - 1], radix_) || !validDigit(text[position + 1], radix_)))) {
          invalid();
        }

        continue;
      }

      if (!validDigit(byte, radix_)) {
        invalid();
      }

      digits_.push_back(runtime::asciiLower(byte));
      if (!point_seen) {
        ++point_;
      }
    }

    if (digits_.empty()) {
      invalid();
    }
  }

  static std::ptrdiff_t exponent(std::string_view text, std::size_t source_bytes) {
    const bool negative = text.starts_with('-');
    if (negative || text.starts_with('+')) {
      text.remove_prefix(1);
    }

    if (text.empty()) {
      invalid();
    }

    const auto budget = static_cast<std::ptrdiff_t>(source_bytes) + minimum_exponent_budget;
    std::ptrdiff_t value = 0;
    for (std::size_t position = 0; position < text.size(); ++position) {
      if (text[position] == '_') {
        if (position == 0 || position + 1 == text.size() || !validDigit(text[position - 1], decimal_radix) || !validDigit(text[position + 1], decimal_radix)) {
          invalid();
        }

        continue;
      }

      if (!validDigit(text[position], decimal_radix)) {
        invalid();
      }

      value = std::min(budget, (value * decimal_radix) + static_cast<std::ptrdiff_t>(text[position] - '0'));
    }

    return negative ? -value : value;
  }

  void applyExponent(std::ptrdiff_t value) {
    if (radix_ == decimal_radix) {
      point_ += value;

      return;
    }

    auto whole = value / hexadecimal_bits;
    auto remainder = value % hexadecimal_bits;
    if (remainder < 0) {
      --whole;
      remainder += hexadecimal_bits;
    }

    point_ += whole;
    unsigned carry = 0;
    for (auto digit = digits_.rbegin(); digit != digits_.rend(); ++digit) {
      const auto product = (static_cast<unsigned>(digit_symbols.find(*digit)) << static_cast<unsigned>(remainder)) + carry;
      *digit = digit_symbols[product % radix_];
      carry = product / radix_;
    }

    if (carry != 0) {
      digits_.insert(digits_.begin(), digit_symbols[carry]);
      ++point_;
    }
  }

  void normalize() {
    const auto first = digits_.find_first_not_of('0');
    if (first == std::string_view::npos) {
      digits_.clear();
      point_ = 0;

      return;
    }

    digits_.erase(0, first);
    point_ -= static_cast<std::ptrdiff_t>(first);
    while (digits_.back() == '0') {
      digits_.pop_back();
    }
  }

  String<Memory> digits_;
  std::ptrdiff_t point_ = 0;
  unsigned radix_ = decimal_radix;
  bool negative_ = false;
};

}
}

// Interface: text/json_unsigned_integer.cppm
export {
namespace telar::gui {

struct JsonUnsignedInteger {
  static constexpr unsigned binary128_significand_bits = 113;
  static constexpr unsigned binary128_minimum_normal_exponent = 16382;
  static constexpr unsigned zero_half_exponent = binary128_minimum_normal_exponent + binary128_significand_bits;
  static constexpr unsigned ordinary_half_exponent = binary128_significand_bits + 1;
  static constexpr unsigned hexadecimal_bits = 4;

  [[nodiscard]] inline static bool integerSyntax(std::string_view text) noexcept {
    return text != "-0" && text.find_first_of(".eE") == std::string_view::npos;
  }

  template <std::unsigned_integral Number, Allocator Memory>
  [[nodiscard]] inline static Number parse(Memory &memory, std::string_view text, bool allow_float = true) {
    static_assert(std::numeric_limits<Number>::digits <= std::numeric_limits<std::uint16_t>::digits);

    const bool floating = !integerSyntax(text);
    if (floating && !allow_float) {
      invalid();
    }

    const RadixNumber number{memory, text, floating};
    const auto maximum = static_cast<std::uint32_t>(std::numeric_limits<Number>::max());
    const auto integral = number.integerPart(maximum);
    if (number.integral()) {
      if (number.negative() && integral != 0) {
        invalid();
      }

      return static_cast<Number>(integral);
    }

    if (!floating) {
      invalid();
    }

    return static_cast<Number>(rounded(number, integral, maximum));
  }

private:
  [[noreturn]] inline static void invalid() {
    throw std::invalid_argument{"JSON number is not a representable unsigned integer"};
  }

  template <Allocator Memory>
  inline static std::uint32_t rounded(const RadixNumber<Memory> &number, std::uint32_t integral, std::uint32_t maximum) {
    if (!number.negative()) {
      if (integral != 0) {
        const auto exponent = binary128_significand_bits - (std::bit_width(integral) - 1);
        const BinaryFraction<ordinary_half_exponent> upper{exponent, number.radix()};
        if (number.compareFraction(upper) <= 0) {
          return integral;
        }
      }

      if (integral < maximum) {
        const auto next = integral + 1;
        const auto exponent = binary128_significand_bits - (std::bit_width(next) - 1) + static_cast<unsigned>(std::has_single_bit(next));
        const BinaryFraction<ordinary_half_exponent> lower{exponent, number.radix()};
        if (number.compareFraction(lower, true) >= 0) {
          return next;
        }
      }
    }

    if (integral == 0 && number.fractionLeadingZeros() >= (zero_half_exponent - 1) / hexadecimal_bits) {
      if (number.radix() == NumberRadix::decimal) {
        static const BinaryFraction<zero_half_exponent> zero{zero_half_exponent};
        if (number.compareFraction(zero) <= 0) {
          return 0;
        }
      } else {
        const BinaryFraction<zero_half_exponent> zero{zero_half_exponent, NumberRadix::hexadecimal};
        if (number.compareFraction(zero) <= 0) {
          return 0;
        }
      }
    }

    invalid();
  }
};

}
}

// Interface: text/label_text.cppm
export {
namespace telar::gui {

inline constexpr std::size_t label_text_capacity = 256;
using LabelText = BoundedText<label_text_capacity>;

}
}

// Interface: text/text_fit.cppm
export {
namespace telar::gui {

template <typename Measure>
concept LabelMeasure = requires(Measure &measure, std::string_view text) {
  { measure(text) } -> std::convertible_to<float>;
};

struct TextFit {
  static constexpr std::size_t maximum_bytes = label_text_capacity;
  static constexpr std::string_view ellipsis = "…";
  using Buffer = std::array<char, maximum_bytes>;

  template <LabelMeasure Measure>
  [[nodiscard]] inline static std::string_view fit(std::string_view text, float width, Measure &measure, Buffer &buffer) {
    if (!std::isfinite(width)) {
      throw std::invalid_argument{"InvalidTextFitWidth"};
    }

    const auto full = measureText(measure, text);
    if (full <= width) {
      return text;
    }

    const auto tail = measureText(measure, ellipsis);
    if (tail > width) {
      return {};
    }

    const auto prefixes = collectPrefixes(text);
    const auto room = width - tail;
    const auto estimate = static_cast<std::size_t>(std::floor(static_cast<float>(prefixes.graphemes) * room / full));
    auto keep = std::min(estimate, prefixes.stored);
    while (keep > 0 && measureText(measure, text.substr(0, prefixes.bytes[keep])) > room) {
      --keep;
    }

    const auto prefix = text.substr(0, prefixes.bytes[keep]);
    auto *output = std::ranges::copy(prefix, buffer.begin()).out;
    output = std::ranges::copy(ellipsis, output).out;

    return {buffer.data(), static_cast<std::size_t>(output - buffer.begin())};
  }

private:
  template <LabelMeasure Measure>
  [[nodiscard]] inline static float measureText(Measure &measure, std::string_view text) {
    const auto width = static_cast<float>(measure(text));
    if (!std::isfinite(width) || width < 0) {
      throw std::invalid_argument{"InvalidTextFitMeasurement"};
    }

    return width;
  }

  struct Prefixes {
    std::array<std::size_t, maximum_bytes> bytes{};
    std::size_t graphemes = 0;
    std::size_t stored = 0;
  };

  [[nodiscard]] inline static Prefixes collectPrefixes(std::string_view text) {
    GraphemeCursor cursor{text};
    Prefixes result;
    std::size_t bytes = 0;
    while (const auto cluster = cursor.next()) {
      ++result.graphemes;
      bytes += cluster->size();
      if (bytes <= maximum_bytes - ellipsis.size()) {
        result.bytes[++result.stored] = bytes;
      }
    }

    return result;
  }
};

}
}
