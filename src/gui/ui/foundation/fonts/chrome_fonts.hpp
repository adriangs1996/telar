#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/memory.hpp"
#include "tbc/view.hpp"
#include <cstdint>
#include <memory>
#include <string_view>

#pragma once

import telar.gui.foundation.fonts;

namespace telar::gui::qt {

  class ChromeFonts {
  public:
    ChromeFonts();
    [[nodiscard]] fonts::Face& face(bool emphasized) noexcept;
    [[nodiscard]] fonts::Face& face(fonts::FontRole role);
    [[nodiscard]] bool covers(std::string_view text, bool emphasized) const;
    [[nodiscard]] static std::shared_ptr<ChromeFonts> shared();

  private:
    SystemAllocator memory_;
    Vector<std::uint8_t, SystemAllocator> regular_bytes_;
    Vector<std::uint8_t, SystemAllocator> emphasized_bytes_;
    // The faces read the bytes stored beside them.
    tbc::view<fonts::Face, tbc::lt::self> regular_;
    tbc::view<fonts::Face, tbc::lt::self> emphasized_;
  };

}
