#pragma once

#include "presentation/theme.hpp"
#include "theme_presets.hpp"
#include <algorithm>
#include <stdexcept>

namespace telar::gui {

inline std::string_view canonicalThemeName(std::string_view name) noexcept {
  if (name == "osaka-jade" || name == "osaka_jade" || name == "osakajade") {
    return "shade";
  }
  if (name == "catppuccin-mocha" || name == "mocha") {
    return "catppuccin";
  }
  if (name == "tokyonight" || name == "tokyo_night") {
    return "tokyo-night";
  }
  if (name == "kanagawa-wave" || name == "kanagawa_wave") {
    return "kanagawa";
  }
  if (name == "kanagawa_dragon") {
    return "kanagawa-dragon";
  }
  if (name == "default") {
    return "terminal";
  }

  return name;
}

inline ThemeValues themeValuesByName(std::string_view name) {
  constexpr std::size_t maximum_name_bytes = 64;
  if (name.size() > maximum_name_bytes) {
    throw std::invalid_argument{"GUI theme name exceeds capacity"};
  }

  std::array<char, maximum_name_bytes> lowercase{};
  std::ranges::transform(name, lowercase.begin(), [](char character) {
    return character >= 'A' && character <= 'Z' ? static_cast<char>(character + 'a' - 'A') : character;
  });
  const auto canonical = canonicalThemeName({lowercase.data(), name.size()});
  const auto *const found = std::ranges::find_if(theme_presets, [&](const auto &preset) {
    return preset.name == canonical;
  });
  if (found == theme_presets.end()) {
    throw std::invalid_argument{"Unknown GUI theme"};
  }

  return found->values;
}

inline Theme themeByName(std::string_view name) {
  return projectTheme(themeValuesByName(name));
}

}
