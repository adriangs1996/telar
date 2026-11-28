export module telar.gui.ui.kit.fonts:resident_fonts;

import std;
import telar.gui.qt;
import telar.tbc;
import :chrome_fonts;
import :font_asset;
import :font_collection;
import telar.gui.foundation.fonts;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  // The faces a window shares. A face it hands out is a member that never moves, fallbacks included, so
  // a reference to it stays valid whatever is done through the fonts.
  class [[tbc::shared]] ResidentFonts {
  public:
    explicit ResidentFonts(std::shared_ptr<const FontAsset> source);
    explicit ResidentFonts(std::shared_ptr<const FontCollection> collection);
    [[nodiscard]] fonts::Face& face(fonts::FontRole role);
    [[nodiscard]] const FontAsset& asset(fonts::FontRole role) const;
    [[nodiscard]] ds::Option<fonts::FontRole> source(std::string_view text, fonts::FontRole preferred);
    [[nodiscard]] std::size_t fallbackCount() const noexcept;
    [[nodiscard]] static std::shared_ptr<const FontAsset> resolveSource(const QString& family, const QString& style);
    // The fonts come from a process-wide cache, which keeps its own share of the source.
    [[nodiscard]] static tbc::val_static<std::shared_ptr<ResidentFonts>> shared(const std::shared_ptr<const FontAsset>& source);
    [[nodiscard]] static tbc::val_static<std::shared_ptr<ResidentFonts>> shared(const std::shared_ptr<const FontCollection>& collection);

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
