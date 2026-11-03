#pragma once

#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>

namespace telar::runtime::machines {

template <std::size_t Capacity>
class BoundedText {
public:
  void append(std::string_view text) {
    if (text.size() > Capacity - length_) {
      throw std::length_error{"Text capacity exceeded"};
    }

    if (!text.empty()) {
      std::memmove(storage_.data() + length_, text.data(), text.size());
      length_ += text.size();
    }
  }

  template <std::unsigned_integral Number>
  void appendDecimal(Number number) {
    const auto result = std::to_chars(storage_.data() + length_, storage_.data() + Capacity, number);
    if (result.ec != std::errc{}) {
      throw std::length_error{"Text capacity exceeded"};
    }

    length_ = static_cast<std::size_t>(result.ptr - storage_.data());
  }

  void truncate(std::size_t length) {
    if (length > length_) {
      throw std::out_of_range{"Text truncation exceeds length"};
    }

    length_ = length;
  }

  [[nodiscard]] std::string_view view() const noexcept {
    return {storage_.data(), length_};
  }

private:
  std::array<char, Capacity> storage_{};
  std::size_t length_ = 0;
};

}
