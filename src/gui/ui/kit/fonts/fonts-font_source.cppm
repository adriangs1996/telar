export module telar.gui.ui.kit.fonts:font_source;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  struct FontData {
    QByteArray bytes;
    fonts::FontMatch match{};
  };

  // A font file's bytes as the font library reads them.
  [[tbc::hot_path]] [[nodiscard]] inline std::span<const std::uint8_t> byteSpan(const QByteArray& bytes) noexcept {
    return telar::byteView({bytes.constData(), static_cast<std::size_t>(bytes.size())});
  }

  FontData loadFontData(const FontConfiguration& font);
  QByteArray loadFontBytes(const QString& path);
  ds::Option<FontData> loadFallbackFontData(const fonts::FontQuery& query);

  template <Allocator Memory>
  class FontSource {
  public:
    // The source reads the font into memory, region `a`, and keeps nothing of the configuration.
    [[tbc::generic]] explicit FontSource(tbc::mut_a<Memory> memory, const FontConfiguration& font)
        : bytes_(memory) {
      const auto data = loadFontData(font);

      bytes_.clear();
      bytes_.extend(byteSpan(data.bytes));
      match_ = data.match;
    }

    [[tbc::generic]] [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
      return bytes_;
    }

    [[tbc::generic]] [[nodiscard]] const fonts::FontMatch& match() const noexcept {
      return match_;
    }

  private:
    tbc::val_a<ds::Vec<std::uint8_t, Memory>> bytes_;
    fonts::FontMatch match_{};
  };

}
