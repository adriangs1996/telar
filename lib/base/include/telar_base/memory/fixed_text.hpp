#pragma once

#include "telar_base/ds/values.hpp"
#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <type_traits>

namespace telar::runtime {

  template <std::size_t Capacity>
  class FixedText {
  public:
    FixedText() noexcept {}

    FixedText(const FixedText& other) noexcept {
      copy(other.view());
    }

    FixedText& operator=(const FixedText& other) noexcept {
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

    [[nodiscard]] std::string_view view() const noexcept {
      return {bytes_.data(), length_};
    }

    // Equal texts are equal, whatever the bytes past them hold.
    friend bool operator==(const FixedText& left, const FixedText& right) noexcept {
      return left.view() == right.view();
    }

  private:
    void copy(std::string_view text) noexcept {
      if (!text.empty()) {
        std::memmove(bytes_.dataMut(), text.data(), text.size());
      }

      length_ = text.size();
    }

    ds::Array<char, Capacity> bytes_;
    std::size_t length_ = 0;
  };

  // The message an error carries. It joins its parts when the error is thrown and keeps what fits
  // in its capacity, so throwing never allocates and never fails for lack of memory; the NUL after
  // it lets `what()` hand it out as it is.
  //
  // The parts are separate arguments, each read as a std::string_view: a braced pair of texts would
  // otherwise build one view from two unrelated pointers.
  template <std::size_t Capacity>
  class ErrorText {
  public:
    template <typename... Parts>
      requires(sizeof...(Parts) != 0 && (std::is_convertible_v<const Parts&, std::string_view> && ...))
    explicit ErrorText(const Parts&... parts) noexcept {
      (append(parts), ...);
      bytes_.atMut(length_) = '\0';
    }

    [[nodiscard]] const char* c_str() const noexcept {
      return bytes_.data();
    }

    [[nodiscard]] std::string_view view() const noexcept {
      return {bytes_.data(), length_};
    }

  private:
    void append(std::string_view part) noexcept {
      const auto count = std::min(part.size(), Capacity - length_);
      if (count != 0) {
        std::memcpy(bytes_.dataMut() + length_, part.data(), count);
      }

      length_ += count;
    }

    ds::Array<char, Capacity + 1> bytes_;
    std::size_t length_ = 0;
  };

}
