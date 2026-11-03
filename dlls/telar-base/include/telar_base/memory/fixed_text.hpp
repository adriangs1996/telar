#pragma once

#include <array>
#include <cstring>
#include <stdexcept>
#include <string_view>

namespace telar::runtime {

template <std::size_t Capacity>
class FixedText {
public:
  FixedText() noexcept {}

  FixedText(const FixedText &other) noexcept {
    copy(other.view());
  }

  FixedText &operator=(const FixedText &other) noexcept {
    if (this != &other) {
      copy(other.view());
    }

    return *this;
  }

  void assign(std::string_view text) {
    if (text.size() > Capacity) {
      throw std::length_error{"Fixed text capacity exceeded"};
    }

    copy(text);
  }

  std::string_view view() const noexcept {
    return {bytes_.data(), length_};
  }

private:
  void copy(std::string_view text) noexcept {
    if (!text.empty()) {
      std::memmove(bytes_.data(), text.data(), text.size());
    }

    length_ = text.size();
  }

  std::array<char, Capacity> bytes_;
  std::size_t length_ = 0;
};

}
