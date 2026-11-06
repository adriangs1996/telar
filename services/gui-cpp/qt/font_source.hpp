#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/memory.hpp"
#include <bit>
#include <stdexcept>
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <cmath>
#include <limits>
#include <type_traits>
#include <QByteArray>
#include <QString>

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

FontData loadFontData(const FontConfiguration &font);
QByteArray loadFontBytes(const QString &path);
std::optional<FontData> loadFallbackFontData(const fonts::FontQuery &query);

template <Allocator Memory>
class FontSource {
public:
  explicit FontSource(Memory &memory, const FontConfiguration &font)
      : bytes_(AllocatorRef<std::uint8_t, Memory>{memory}) {
    const auto data = loadFontData(font);
    bytes_.assign(data.bytes.cbegin(), data.bytes.cend());
    match_ = data.match;
  }

  [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
    return bytes_;
  }

  [[nodiscard]] const fonts::FontMatch &match() const noexcept {
    return match_;
  }

private:
  Vector<std::uint8_t, Memory> bytes_;
  fonts::FontMatch match_{};
};

}
