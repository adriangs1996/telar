#pragma once

#include "number_radix.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/text/ascii.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::machines {

template <Allocator Memory>
class RadixNumber {
public:
  static constexpr unsigned decimal_radix = static_cast<unsigned>(NumberRadix::decimal);
  static constexpr unsigned hexadecimal_radix = static_cast<unsigned>(NumberRadix::hexadecimal);
  static constexpr unsigned hexadecimal_bits = 4;

  RadixNumber(Memory &memory, std::string_view text, bool floating_syntax)
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

  [[nodiscard]] bool negative() const noexcept {
    return negative_;
  }

  [[nodiscard]] NumberRadix radix() const noexcept {
    return static_cast<NumberRadix>(radix_);
  }

  [[nodiscard]] bool zero() const noexcept {
    return digits_.empty();
  }

  [[nodiscard]] bool integral() const noexcept {
    return point_ >= static_cast<std::ptrdiff_t>(digits_.size());
  }

  [[nodiscard]] std::size_t fractionLeadingZeros() const noexcept {
    return point_ < 0 ? static_cast<std::size_t>(-point_) : 0;
  }

  [[nodiscard]] std::uint32_t integerPart(std::uint32_t maximum) const {
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
  [[nodiscard]] int compareFraction(const Fraction &threshold, bool complement = false) const noexcept {
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
