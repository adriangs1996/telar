#pragma once

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>

namespace telar::gui::fonts {

class Face;

enum class FontRole : std::uint8_t {
  regular,
  emphasized,
  primary,
  text,
  symbols,
  fallback_0,
  fallback_1,
  fallback_2,
  fallback_3,
  fallback_4,
  fallback_5,
  fallback_6,
  fallback_7,
};

inline constexpr std::size_t maximum_fallback_faces = 8;

[[nodiscard]] constexpr FontRole fallbackRole(std::size_t index) noexcept {
  return static_cast<FontRole>(std::to_underlying(FontRole::fallback_0) + index);
}

[[nodiscard]] constexpr std::optional<std::size_t> fallbackIndex(FontRole role) noexcept {
  if (role < FontRole::fallback_0 || role > FontRole::fallback_7) {
    return std::nullopt;
  }

  return std::to_underlying(role) - std::to_underlying(FontRole::fallback_0);
}

template <typename Fonts>
concept FontProvider = requires(Fonts &fonts, FontRole role) {
  { fonts.face(role) } -> std::same_as<Face &>;
};

[[nodiscard]] constexpr bool fittedFont(FontRole role) noexcept {
  return role == FontRole::text || role == FontRole::symbols || fallbackIndex(role).has_value();
}

}
