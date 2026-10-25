#pragma once

#include "erase_sensitive.hpp"
#include <array>
#include <cstring>
#include <stdexcept>
#include <string_view>

namespace telar::runtime {

template <std::size_t Capacity>
class SensitiveText {
public:
  SensitiveText() noexcept {}

  ~SensitiveText() {
    clear();
  }

  SensitiveText(const SensitiveText &other) noexcept {
    copy(other);
  }

  SensitiveText &operator=(const SensitiveText &other) noexcept {
    if (this != &other) {
      clear();
      copy(other);
    }

    return *this;
  }

  SensitiveText(SensitiveText &&other) noexcept {
    copy(other);
    other.clear();
  }

  SensitiveText &operator=(SensitiveText &&other) noexcept {
    if (this != &other) {
      clear();
      copy(other);
      other.clear();
    }

    return *this;
  }

  void append(std::string_view text) {
    if (text.size() > Capacity - length_) {
      throw std::length_error{"Sensitive text exceeds its capacity"};
    }

    if (!text.empty()) {
      std::memcpy(bytes_.data() + length_, text.data(), text.size());
      length_ += text.size();
    }
  }

  void truncate(std::size_t length) noexcept {
    if (length < length_) {
      eraseSensitive(bytes_.data() + length, length_ - length);
      length_ = length;
    }
  }

  void clear() noexcept {
    truncate(0);
  }

  std::string_view view() const noexcept {
    return {bytes_.data(), length_};
  }

private:
  void copy(const SensitiveText &other) noexcept {
    length_ = other.length_;
    std::memcpy(bytes_.data(), other.bytes_.data(), length_);
  }

  std::array<char, Capacity> bytes_;
  std::size_t length_ = 0;
};

}
