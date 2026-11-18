#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "chrome_fonts.hpp"
#include "font_asset.hpp"
#include "font_collection.hpp"
#include "platform/font.h"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include <QByteArray>
#include <QString>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <freetype/freetype.h>
#include <hb.h>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <utility>

#pragma once

#include "tbc/view.hpp"

import telar.gui.foundation.fonts;
import telar.base.ds;

namespace telar::gui::qt {

  // The faces a window shares. A face it hands out is a member that never moves, fallbacks included, so
  // a reference to it stays valid whatever is done through the fonts.
  class TBC_SHARED ResidentFonts {
  public:
    explicit ResidentFonts(std::shared_ptr<const FontAsset> source);
    explicit ResidentFonts(std::shared_ptr<const FontCollection> collection);
    [[nodiscard]] fonts::Face& face(fonts::FontRole role);
    [[nodiscard]] const FontAsset& asset(fonts::FontRole role) const;
    [[nodiscard]] ds::Option<fonts::FontRole> source(std::string_view text, fonts::FontRole preferred);
    [[nodiscard]] std::size_t fallbackCount() const noexcept;
    [[nodiscard]] static std::shared_ptr<const FontAsset> resolveSource(const QString& family, const QString& style);
    // The fonts come from a process-wide cache, which keeps its own share of the source.
    [[nodiscard]] static tbc::view<std::shared_ptr<ResidentFonts>, tbc::lt::static_storage> shared(const std::shared_ptr<const FontAsset>& source);
    [[nodiscard]] static tbc::view<std::shared_ptr<ResidentFonts>, tbc::lt::static_storage> shared(const std::shared_ptr<const FontCollection>& collection);

  private:
    std::shared_ptr<const FontAsset> primary_source_;
    std::shared_ptr<const FontAsset> text_source_;
    std::shared_ptr<const FontAsset> symbols_source_;
    std::shared_ptr<ChromeFonts> chrome_;
    std::shared_ptr<const FontCollection> collection_;
    fonts::Face primary_;
    fonts::Face text_;
    fonts::Face symbols_;
    ds::Array<ds::Option<fonts::Face>, fonts::maximum_fallback_faces> fallbacks_;
  };

}
