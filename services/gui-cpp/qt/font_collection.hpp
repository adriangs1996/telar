#pragma once

#include "font_asset.hpp"
#include "fonts/font_role.hpp"
#include <array>
#include <cstddef>
#include <memory>

namespace telar::gui::qt {

struct FontCollection {
  std::shared_ptr<const FontAsset> primary;
  std::array<std::shared_ptr<const FontAsset>, fonts::maximum_fallback_faces> fallback{};
  std::size_t count = 0;
};

}
