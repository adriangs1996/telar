#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "chrome_fonts.hpp"
#include "font_asset.hpp"
#include "font_collection.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <array>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <string_view>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include "telar_client/serializers/telar_cells.hpp"
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <concepts>
#include <utility>
#include <QByteArray>
#include <QString>

#pragma once

#include "tbc/view.hpp"



import telar.gui.fonts.face;

namespace telar::gui::qt {

// The faces a window shares. A face it hands out is a member that never moves, fallbacks included, so
// a reference to it stays valid whatever is done through the fonts.
class TBC_SHARED ResidentFonts {
public:
  explicit ResidentFonts(std::shared_ptr<const FontAsset> source);
  explicit ResidentFonts(std::shared_ptr<const FontCollection> collection);
  [[nodiscard]] fonts::Face &face(fonts::FontRole role);
  [[nodiscard]] const FontAsset &asset(fonts::FontRole role) const;
  [[nodiscard]] std::optional<fonts::FontRole> source(std::string_view text, fonts::FontRole preferred);
  [[nodiscard]] std::size_t fallbackCount() const noexcept;
  [[nodiscard]] static std::shared_ptr<const FontAsset> resolveSource(const QString &family, const QString &style);
  // The fonts come from a process-wide cache, which keeps its own share of the source.
  [[nodiscard]] static tbc::view<std::shared_ptr<ResidentFonts>, tbc::lt::static_storage> shared(const std::shared_ptr<const FontAsset> &source);
  [[nodiscard]] static tbc::view<std::shared_ptr<ResidentFonts>, tbc::lt::static_storage> shared(const std::shared_ptr<const FontCollection> &collection);

private:
  std::shared_ptr<const FontAsset> primary_source_;
  std::shared_ptr<const FontAsset> text_source_;
  std::shared_ptr<const FontAsset> symbols_source_;
  std::shared_ptr<ChromeFonts> chrome_;
  std::shared_ptr<const FontCollection> collection_;
  fonts::Face primary_;
  fonts::Face text_;
  fonts::Face symbols_;
  std::array<std::optional<fonts::Face>, fonts::maximum_fallback_faces> fallbacks_;
};

}
