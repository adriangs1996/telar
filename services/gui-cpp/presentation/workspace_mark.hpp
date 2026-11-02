#pragma once

#include "core/theme_values.hpp"
#include "core/unicode_scalar.hpp"
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

struct WorkspaceMark {
  static constexpr auto hues = std::to_array<PaletteRole>({PaletteRole::red, PaletteRole::peach, PaletteRole::yellow, PaletteRole::green, PaletteRole::teal, PaletteRole::blue, PaletteRole::mauve});

  Utf8Scalar initial;
  PaletteRole hue = hues.front();

  [[nodiscard]] static WorkspaceMark resolve(std::string_view name) {
    WorkspaceMark mark;
    mark.hue = hues[hash(name) % hues.size()];
    if (name.empty()) {
      return mark;
    }

    const auto leading = std::countl_one(static_cast<std::uint8_t>(name.front()));
    const auto length = leading == 0 ? std::size_t{1} : static_cast<std::size_t>(leading);
    if (leading == 1 || length > mark.initial.bytes.size() || length > name.size()) {
      return mark;
    }

    try {
      const auto scalar = Utf8Scalar::decode(name.substr(0, length));
      const auto upper = scalar >= 'a' && scalar <= 'z' ? scalar - ('a' - 'A') : scalar;
      mark.initial = Utf8Scalar::encode(upper);
    } catch (const std::invalid_argument &) {
      return mark;
    }

    return mark;
  }

private:
  [[nodiscard]] static std::uint32_t hash(std::string_view name) noexcept {
    constexpr std::uint32_t offset_basis = 2166136261U;
    constexpr std::uint32_t prime = 16777619U;
    auto value = offset_basis;
    for (const auto byte : name) {
      value = (value ^ static_cast<unsigned char>(byte)) * prime;
    }

    return value;
  }
};

}
