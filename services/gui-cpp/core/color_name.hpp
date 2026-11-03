#pragma once

#include "telar_base/text/ascii.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "theme_values.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <variant>

namespace telar::gui {

struct ColorName {
  using Value = std::variant<CellColor, PaletteRole>;

  [[nodiscard]] static std::optional<Value> parse(std::string_view name) noexcept {
    if (runtime::asciiEqualIgnoreCase(name, "default")) {
      return CellColor{};
    }

    for (std::size_t index = 0; index < palette_names.size(); ++index) {
      if (sameRole(name, palette_names[index])) {
        return static_cast<PaletteRole>(index);
      }
    }

    return literal(name);
  }

private:
  [[nodiscard]] static bool sameRole(std::string_view left, std::string_view right) noexcept {
    if (left.size() != right.size()) {
      return false;
    }

    for (std::size_t index = 0; index < left.size(); ++index) {
      const auto normalize = [](char byte) {
        return byte == '-' ? '_' : runtime::asciiLower(byte);
      };
      if (normalize(left[index]) != normalize(right[index])) {
        return false;
      }
    }

    return true;
  }

  [[nodiscard]] static std::optional<Value> literal(std::string_view name) noexcept {
    constexpr std::string_view pattern = "#RRGGBB";
    constexpr std::string_view digits = "0123456789abcdef";
    if (name.size() != pattern.size() || name.front() != '#') {
      return std::nullopt;
    }

    name.remove_prefix(1);
    const bool negative = name.front() == '-';
    if (negative || name.front() == '+') {
      name.remove_prefix(1);
    }

    if (name.front() == '_' || name.back() == '_') {
      return std::nullopt;
    }

    std::uint32_t value = 0;
    for (const auto byte : name) {
      if (byte == '_') {
        continue;
      }

      const auto digit = digits.find(runtime::asciiLower(byte));
      if (digit == std::string_view::npos || (negative && digit != 0)) {
        return std::nullopt;
      }

      value = (value * static_cast<std::uint32_t>(digits.size())) + static_cast<std::uint32_t>(digit);
    }

    constexpr unsigned channel_bits = 8;

    return CellColor{.kind = CellColor::Kind::rgb, .channels = {static_cast<Byte>(value >> (channel_bits * 2)), static_cast<Byte>(value >> channel_bits), static_cast<Byte>(value)}};
  }
};

}
