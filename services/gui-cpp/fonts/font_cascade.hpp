#pragma once

#include "font_coverage.hpp"
#include "font_role.hpp"
#include <array>
#include <optional>
#include <string_view>

namespace telar::gui::fonts {

struct FontCascade {
  template <FontProvider Fonts>
  [[nodiscard]] static std::optional<FontRole> source(Fonts &fonts, std::string_view text, FontRole preferred) {
    if (FontCoverage::covers(fonts.face(preferred), text)) {
      return preferred;
    }

    constexpr std::array fallback{FontRole::primary, FontRole::text, FontRole::symbols};
    for (const auto role : fallback) {
      if (FontCoverage::covers(fonts.face(role), text)) {
        return role;
      }
    }

    if constexpr (requires { fonts.fallbackCount(); }) {
      for (std::size_t index = 0; index < fonts.fallbackCount(); ++index) {
        const auto role = fallbackRole(index);
        if (FontCoverage::covers(fonts.face(role), text)) {
          return role;
        }
      }
    }

    return std::nullopt;
  }
};

}
