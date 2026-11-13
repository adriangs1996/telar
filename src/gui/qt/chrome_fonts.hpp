#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../core/memory.hpp"
#include "../platform/font.h"
#include "tbc/view.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <freetype/freetype.h>
#include <hb.h>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <utility>

#pragma once

#include "core/memory.hpp"

import telar.gui.fonts.face;

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
