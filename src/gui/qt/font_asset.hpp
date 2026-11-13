#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include "tbc/view.hpp"
#include "font_source.hpp"
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include <span>
#include <cstdint>

#pragma once

#include "core/memory.hpp"


import telar.gui.fonts.face;

namespace telar::gui::qt {

class FontAsset {
public:
  explicit FontAsset(const FontData &data)
      : bytes_(data.bytes.cbegin(), data.bytes.cend(), AllocatorRef<std::uint8_t, SystemAllocator>{memory_}),
        match_(data.match) {}

  ~FontAsset() = default;
  FontAsset(const FontAsset &) = delete;
  FontAsset &operator=(const FontAsset &) = delete;
  FontAsset(FontAsset &&) = delete;
  FontAsset &operator=(FontAsset &&) = delete;

  [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
    return bytes_;
  }

  [[nodiscard]] const fonts::FontMatch &match() const noexcept {
    return match_;
  }

private:
  SystemAllocator memory_;
  // Allocated from memory_, which the asset owns.
  tbc::view<Vector<std::uint8_t, SystemAllocator>, tbc::lt::self> bytes_;
  fonts::FontMatch match_;
};

}
