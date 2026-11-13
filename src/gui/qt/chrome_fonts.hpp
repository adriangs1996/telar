#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "../core/memory.hpp"
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
#include <concepts>
#include <utility>

#pragma once

#include "core/memory.hpp"


import telar.gui.fonts.face;

namespace telar::gui::qt {

class ChromeFonts {
public:
  ChromeFonts();
  [[nodiscard]] fonts::Face &face(bool emphasized) noexcept;
  [[nodiscard]] fonts::Face &face(fonts::FontRole role);
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
