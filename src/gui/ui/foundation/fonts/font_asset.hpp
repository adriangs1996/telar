#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "font_source.hpp"
#include "foundation/core/memory.hpp"
#include "tbc/view.hpp"
#include <cstdint>
#include <span>

#pragma once

import telar.gui.foundation.fonts;
import telar.base.ds;

namespace telar::gui::qt {

  class FontAsset {
  public:
    explicit FontAsset(const FontData& data)
        : bytes_(memory_, byteSpan(data.bytes)),
          match_(data.match) {}

    ~FontAsset() = default;
    FontAsset(const FontAsset&) = delete;
    FontAsset& operator=(const FontAsset&) = delete;
    FontAsset(FontAsset&&) = delete;
    FontAsset& operator=(FontAsset&&) = delete;

    [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
      return bytes_;
    }

    [[nodiscard]] const fonts::FontMatch& match() const noexcept {
      return match_;
    }

  private:
    SystemAllocator memory_;
    // Allocated from memory_, which the asset owns.
    tbc::view<ds::Vec<std::uint8_t, SystemAllocator>, tbc::lt::self> bytes_;
    fonts::FontMatch match_;
  };

}
