#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::runtime::control {

inline std::string_view takeField(std::string_view &remaining, char separator = ';') noexcept {
  const auto end = remaining.find(separator);
  const auto result = remaining.substr(0, end);
  remaining = end == std::string_view::npos ? std::string_view{} : remaining.substr(end + 1);
  return result;
}

struct Parameters {
  static constexpr std::size_t capacity = 24;
  static constexpr std::size_t intermediate_capacity = 4;
  static constexpr unsigned maximum_digits = 255;
  static constexpr std::uint32_t maximum_value = UINT16_MAX;

  std::array<std::uint16_t, capacity> values{};
  std::array<char, intermediate_capacity> intermediate{};
  std::size_t count = 0;
  std::size_t intermediate_count = 0;
  bool colon = false;
  char final = 0;

  std::string_view modifiers() const noexcept {
    return {intermediate.data(), intermediate_count};
  }

  static std::optional<Parameters> parse(std::string_view body) noexcept {
    if (body.empty()) {
      return std::nullopt;
    }

    Parameters result;
    result.final = body.back();
    body.remove_suffix(1);
    bool intermediate_phase = false;
    std::uint32_t accumulator = 0;
    unsigned digits = 0;
    for (const auto byte : body) {
      if (byte == '\x7f') {
        continue;
      }

      if (!intermediate_phase && byte >= '0' && byte <= '9') {
        if (++digits > maximum_digits) {
          return std::nullopt;
        }
        accumulator = std::min(maximum_value, accumulator * 10 + static_cast<unsigned>(byte - '0'));
        continue;
      }

      if (!intermediate_phase && (byte == ';' || byte == ':')) {
        if (result.count == capacity) {
          return std::nullopt;
        }
        result.values[result.count++] = static_cast<std::uint16_t>(accumulator);
        result.colon |= byte == ':';
        accumulator = 0;
        digits = 0;
        continue;
      }

      const bool prefix = byte >= '<' && byte <= '?' && !intermediate_phase && digits == 0 && result.count == 0;
      if (prefix || (byte >= ' ' && byte <= '/')) {
        if (result.intermediate_count == intermediate_capacity) {
          return std::nullopt;
        }
        result.intermediate[result.intermediate_count++] = byte;
        intermediate_phase |= !prefix;
        continue;
      }

      return std::nullopt;
    }

    if (digits != 0) {
      if (result.count == capacity) {
        return std::nullopt;
      }
      result.values[result.count++] = static_cast<std::uint16_t>(accumulator);
    }
    return result;
  }
};

}
