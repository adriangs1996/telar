#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/memory.hpp"
#include "platform/font.h"
#include "tbc/view.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <QByteArray>
#include <QString>
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
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

#pragma once
#include "core/memory.hpp"

import telar.gui.core.metrics;
import telar.gui.fonts.font_requests;
import telar.gui.fonts.face;

namespace telar::gui::qt {

  struct FontData {
    QByteArray bytes;
    fonts::FontMatch match{};
  };

  FontData loadFontData(const FontConfiguration& font);
  QByteArray loadFontBytes(const QString& path);
  std::optional<FontData> loadFallbackFontData(const fonts::FontQuery& query);

  template <Allocator Memory>
  class FontSource {
  public:
    // The source reads the font into memory, region `a`, and keeps nothing of the configuration.
    explicit FontSource(tbc::view<Memory&, tbc::lt::a> memory, const FontConfiguration& font)
        : bytes_(AllocatorRef<std::uint8_t, Memory>{memory}) {
      const auto data = loadFontData(font);

      bytes_.assign(data.bytes.cbegin(), data.bytes.cend());
      match_ = data.match;
    }

    [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
      return bytes_;
    }

    [[nodiscard]] const fonts::FontMatch& match() const noexcept {
      return match_;
    }

  private:
    tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> bytes_;
    fonts::FontMatch match_{};
  };

}
