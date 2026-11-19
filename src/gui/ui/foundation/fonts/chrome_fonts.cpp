#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "chrome_fonts.hpp"
#include "font_source.hpp"
#include "foundation/core/memory.hpp"
#include "telar_base/ds/containers.hpp"
#include <QByteArray>
#include <QtCore/qstringliteral.h>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string_view>

namespace telar::gui::qt {
  namespace {

    QByteArray bundledFont(bool emphasized) {
      static const auto regular = loadFontBytes(QStringLiteral(":/telar/fonts/IBMPlexSans-Regular.ttf"));
      static const auto semibold = loadFontBytes(QStringLiteral(":/telar/fonts/IBMPlexSans-SemiBold.ttf"));

      return emphasized ? semibold : regular;
    }

    ds::Vec<std::uint8_t, SystemAllocator> fontBytes(SystemAllocator& memory, bool emphasized) {
      const auto bytes = bundledFont(emphasized);

      return ds::Vec<std::uint8_t, SystemAllocator>{memory, byteSpan(bytes)};
    }

  }

  ChromeFonts::ChromeFonts()
      : regular_bytes_(fontBytes(memory_, false)),
        emphasized_bytes_(fontBytes(memory_, true)),
        regular_(regular_bytes_),
        emphasized_(emphasized_bytes_) {}

  fonts::Face& ChromeFonts::face(bool emphasized) noexcept {
    return emphasized ? emphasized_ : regular_;
  }

  fonts::Face& ChromeFonts::face(fonts::FontRole role) {
    if (role != fonts::FontRole::regular && role != fonts::FontRole::emphasized) {
      throw std::invalid_argument{"NonChromeFontRole"};
    }

    return face(role == fonts::FontRole::emphasized);
  }

  bool ChromeFonts::covers(std::string_view text, bool emphasized) const {
    const auto& font = emphasized ? emphasized_ : regular_;

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
