#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "font_asset.hpp"
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <utility>

#pragma once

import telar.gui.foundation.fonts;
import telar.base.ds;

namespace telar::gui::qt {

  struct FontCollection {
    std::shared_ptr<const FontAsset> primary;
    ds::Array<std::shared_ptr<const FontAsset>, fonts::maximum_fallback_faces> fallback{};
    std::size_t count = 0;
  };

}
