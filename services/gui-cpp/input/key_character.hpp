#pragma once

#include "core/unicode_scalar.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>

namespace telar::gui {

struct KeyCharacter {
  [[nodiscard]] static std::uint32_t pack(std::uint32_t codepoint) {
    return std::bit_cast<std::uint32_t>(Utf8Scalar::encode(codepoint).bytes);
  }

  [[nodiscard]] static Utf8Scalar text(std::uint32_t storage) noexcept {
    Utf8Scalar result;
    result.bytes = std::bit_cast<std::array<char, sizeof(storage)>>(storage);
    const auto *const terminator = std::ranges::find(result.bytes, '\0');
    result.length = std::max<std::size_t>(1, static_cast<std::size_t>(terminator - result.bytes.begin()));

    return result;
  }

  [[nodiscard]] static std::uint32_t codepoint(std::uint32_t storage) {
    return Utf8Scalar::decode(text(storage).view());
  }
};

}
