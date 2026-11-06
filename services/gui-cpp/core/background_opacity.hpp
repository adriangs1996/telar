#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>

namespace telar::gui {

  struct BackgroundOpacity {
    enum class Surface : std::size_t {
      sidebar,
      topbar,
      bottombar,
      workspace,
      pane
    };
    static constexpr std::array<const char *, 5> names{"sidebar", "topbar", "bottombar", "workspace", "pane"};
    std::array<std::optional<float>, names.size()> overrides{};

    [[nodiscard]] float resolve(Surface surface, float fallback) const noexcept {
      return overrides[static_cast<std::size_t>(surface)].value_or(fallback);
    }

    [[nodiscard]] float minimum(float fallback) const noexcept {
      auto result = 1.0F;
      for (const auto value : overrides) {
        result = std::min(result, value.value_or(fallback));
      }
      return result;
    }
  };

}
