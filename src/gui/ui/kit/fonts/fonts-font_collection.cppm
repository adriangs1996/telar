export module telar.gui.ui.kit.fonts:font_collection;

import std;
import :font_asset;
import telar.gui.foundation.fonts;
import telar.base.ds;

export namespace telar::gui::qt {

  struct FontCollection {
    std::shared_ptr<const FontAsset> primary;
    ds::Array<std::shared_ptr<const FontAsset>, fonts::maximum_fallback_faces> fallback{};
    std::size_t count = 0;
  };

}
