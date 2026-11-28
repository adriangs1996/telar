export module telar.gui.ui.kit.fonts:font_asset;

import std;
import telar.tbc;
import :font_source;
import telar.gui.foundation.fonts;
import telar.base.ds;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  class FontAsset {
  public:
    [[tbc::hot_path]] inline explicit FontAsset(const FontData& data)
        : bytes_(memory_, byteSpan(data.bytes)),
          match_(data.match) {}

    ~FontAsset() = default;
    FontAsset(const FontAsset&) = delete;
    FontAsset& operator=(const FontAsset&) = delete;
    FontAsset(FontAsset&&) = delete;
    FontAsset& operator=(FontAsset&&) = delete;

    [[tbc::hot_path]] [[nodiscard]] inline std::span<const std::uint8_t> bytes() const noexcept {
      return bytes_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline const fonts::FontMatch& match() const noexcept {
      return match_;
    }

  private:
    SystemAllocator memory_;
    // Allocated from memory_, which the asset owns.
    tbc::val_self<ds::Vec<std::uint8_t, SystemAllocator>> bytes_;
    fonts::FontMatch match_;
  };

}
