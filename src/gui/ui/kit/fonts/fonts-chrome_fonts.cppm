export module telar.gui.ui.kit.fonts:chrome_fonts;

import std;
import telar.tbc;
import telar.gui.foundation.fonts;
import telar.base.ds;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  class ChromeFonts {
  public:
    ChromeFonts();
    [[nodiscard]] fonts::Face& face(bool emphasized) noexcept;
    [[nodiscard]] fonts::Face& face(fonts::FontRole role);
    [[nodiscard]] bool covers(std::string_view text, bool emphasized) const;
    [[nodiscard]] static std::shared_ptr<ChromeFonts> shared();

  private:
    SystemAllocator memory_;
    ds::Vec<std::uint8_t, SystemAllocator> regular_bytes_;
    ds::Vec<std::uint8_t, SystemAllocator> emphasized_bytes_;
    // The faces read the bytes stored beside them.
    tbc::val_self<fonts::Face> regular_;
    tbc::val_self<fonts::Face> emphasized_;
  };

}
