#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "chrome_fonts.hpp"
#include "../core/memory.hpp"
#include "font_source.hpp"
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
#include <bit>
#include <concepts>
#include <utility>
#include <QByteArray>
#include <QtCore/qstringliteral.h>

#include "core/memory.hpp"


import telar.gui.fonts.face;
import telar.gui.fonts.font_requests;

namespace telar::gui::qt {
namespace {

QByteArray bundledFont(bool emphasized) {
  static const auto regular = loadFontBytes(QStringLiteral(":/telar/fonts/IBMPlexSans-Regular.ttf"));
  static const auto semibold = loadFontBytes(QStringLiteral(":/telar/fonts/IBMPlexSans-SemiBold.ttf"));

  return emphasized ? semibold : regular;
}

Vector<std::uint8_t, SystemAllocator> fontBytes(SystemAllocator &memory, bool emphasized) {
  const auto bytes = bundledFont(emphasized);

  return {bytes.cbegin(), bytes.cend(), AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
}

}

ChromeFonts::ChromeFonts()
    : regular_bytes_(fontBytes(memory_, false)),
      emphasized_bytes_(fontBytes(memory_, true)),
      regular_(regular_bytes_),
      emphasized_(emphasized_bytes_) {}

fonts::Face &ChromeFonts::face(bool emphasized) noexcept {
  return emphasized ? emphasized_ : regular_;
}

fonts::Face &ChromeFonts::face(fonts::FontRole role) {
  if (role != fonts::FontRole::regular && role != fonts::FontRole::emphasized) {
    throw std::invalid_argument{"NonChromeFontRole"};
  }

  return face(role == fonts::FontRole::emphasized);
}

bool ChromeFonts::covers(std::string_view text, bool emphasized) const {
  const auto &font = emphasized ? emphasized_ : regular_;

  return fonts::FontCoverage::covers(font, text);
}

std::shared_ptr<ChromeFonts> ChromeFonts::shared() {
  thread_local std::weak_ptr<ChromeFonts> cached;
  auto fonts = cached.lock();
  if (!fonts) {
    fonts = std::make_shared<ChromeFonts>();
    cached = fonts;
  }

  return fonts;
}

}
