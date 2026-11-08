#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "font_asset.hpp"
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <array>
#include <memory>

#pragma once



import telar.gui.fonts.face;

namespace telar::gui::qt {

struct FontCollection {
  std::shared_ptr<const FontAsset> primary;
  std::array<std::shared_ptr<const FontAsset>, fonts::maximum_fallback_faces> fallback{};
  std::size_t count = 0;
};

}
