#pragma once

#include "telar_base/ds/values.hpp"
#include <algorithm>
#include <array>
#include <cstring>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>

namespace telar::runtime {

  template <std::size_t Capacity>
  class FixedText {
  public:
    FixedText() noexcept {} // NOLINT(modernize-use-equals-default): user-provided, so that value-initializing one leaves its bytes unwritten

    // Copies and moves copy only the text, not the bytes past it.
    FixedText(const FixedText& other) noexcept {
      copy(other.view());
    }

    FixedText(FixedText&& other) noexcept {
      copy(other.view());
    }

    FixedText& operator=(const FixedText& other) noexcept {
      if (this != &other) {
        copy(other.view());
      }

      return *this;
    }

    FixedText& operator=(FixedText&& other) noexcept {
      if (this != &other) {
        copy(other.view());
      }

      return *this;
    }

    ~FixedText() = default;

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
    // The text may be a part of this one's, which lies at or after where it goes.
    void copy(std::string_view text) noexcept {
      if (text.data() != bytes_.data()) {
        std::ranges::copy(text, bytes_.viewMut().begin());
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

    [[nodiscard]] const char* cStr() const noexcept {
      return bytes_.data();
    }

    [[nodiscard]] std::string_view view() const noexcept {
      return {bytes_.data(), length_};
    }

  private:
    void append(std::string_view part) noexcept {
      const auto count = std::min(part.size(), Capacity - length_);

      std::ranges::copy(std::span<const char>{part}.first(count), bytes_.viewMut().subspan(length_).begin());
      length_ += count;
    }

    ds::Array<char, Capacity + 1> bytes_;
    std::size_t length_ = 0;
  };

}
