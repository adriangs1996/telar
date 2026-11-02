#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

enum class PaletteMode : std::uint8_t {
  actions = '>',
  navigate = '@',
  suggest = '?',
  machines = ':',
};

struct PaletteQuery {
  static constexpr std::size_t maximum_bytes = 512;

  PaletteMode mode = PaletteMode::navigate;
  std::string_view text;

  [[nodiscard]] static constexpr std::optional<PaletteMode> prefix(char byte) noexcept {
    switch (byte) {
    case static_cast<char>(PaletteMode::actions):
      return PaletteMode::actions;
    case static_cast<char>(PaletteMode::navigate):
      return PaletteMode::navigate;
    case static_cast<char>(PaletteMode::suggest):
      return PaletteMode::suggest;
    case static_cast<char>(PaletteMode::machines):
      return PaletteMode::machines;
    default:
      return std::nullopt;
    }
  }

  [[nodiscard]] static constexpr PaletteQuery parse(std::string_view prompt) noexcept {
    if (!prompt.empty()) {
      if (const auto mode = prefix(prompt.front())) {
        prompt.remove_prefix(1);

        return {.mode = *mode, .text = prompt};
      }
    }

    return {.text = prompt};
  }
};

}
