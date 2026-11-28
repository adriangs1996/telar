module telar.gui.ui.kit.fonts;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    QByteArray bundledFont(bool emphasized) {
      [[clang::no_destroy]] static const auto regular = loadFontBytes(u":/telar/fonts/IBMPlexSans-Regular.ttf"_s);
      [[clang::no_destroy]] static const auto semibold = loadFontBytes(u":/telar/fonts/IBMPlexSans-SemiBold.ttf"_s);

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
    struct [[tbc::shared]] Cache {
      std::weak_ptr<ChromeFonts> fonts;
    };

// A thread that exits must drop its weak reference, or the fonts' shared allocation leaks with it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wexit-time-destructors"
    thread_local Cache cached;
#pragma clang diagnostic pop
    auto fonts = cached.fonts.lock();
    if (!fonts) {
      fonts = std::make_shared<ChromeFonts>();
      cached.fonts = fonts;
    }

    return fonts;
  }

}
