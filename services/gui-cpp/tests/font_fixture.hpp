#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
#include <bit>
#include <concepts>
#include <utility>
#include "telar_base/memory/allocator.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <filesystem>

#pragma once

#include "core/memory.hpp"
#include "platform/font.h"
#include "tbc/view.hpp"


import telar.gui.fonts.face;
import telar.gui.fonts.font_requests;
import telar.platform;

namespace telar::gui::test {

template <Allocator Memory>
class FontFixture {
public:
  FontFixture(Memory &memory, const std::filesystem::path &directory, const char *primary_filename = "JetBrainsMono-Regular.ttf")
      : regular_bytes_(read(memory, directory / "IBMPlexSans-Regular.ttf")),
        emphasized_bytes_(read(memory, directory / "IBMPlexSans-SemiBold.ttf")),
        primary_bytes_(read(memory, directory / primary_filename)),
        text_bytes_(read(memory, directory / "JetBrainsMono-Regular.ttf")),
        symbols_bytes_(read(memory, directory / "SymbolsNerdFontMono-Regular.ttf")),
        regular_(regular_bytes_),
        emphasized_(emphasized_bytes_),
        primary_(primary_bytes_),
        text_(text_bytes_),
        symbols_(symbols_bytes_) {}

  [[nodiscard]] fonts::Face &face(fonts::FontRole role) {
    switch (role) {
    case fonts::FontRole::regular:
      return regular_;
    case fonts::FontRole::emphasized:
      return emphasized_;
    case fonts::FontRole::primary:
      return primary_;
    case fonts::FontRole::text:
      return text_;
    case fonts::FontRole::symbols:
      return symbols_;
    default:
      throw std::invalid_argument{"UnknownFixtureFontRole"};
    }
  }

  [[nodiscard]] std::optional<fonts::FontRole> source(std::string_view text, fonts::FontRole preferred) {
    return fonts::FontCascade::source(*this, text, preferred);
  }

private:
  // The bytes are storage of the allocator, region `a`.
  static tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> read(tbc::view<Memory &, tbc::lt::a> memory, const std::filesystem::path &path) {
    const auto data = runtime::readFile(memory, path.c_str(), telar_font_max_bytes);

    return {data.cbegin(), data.cend(), AllocatorRef<std::uint8_t, Memory>{memory}};
  }

  Vector<std::uint8_t, Memory> regular_bytes_;
  Vector<std::uint8_t, Memory> emphasized_bytes_;
  Vector<std::uint8_t, Memory> primary_bytes_;
  Vector<std::uint8_t, Memory> text_bytes_;
  Vector<std::uint8_t, Memory> symbols_bytes_;
  fonts::Face regular_;
  fonts::Face emphasized_;
  fonts::Face primary_;
  fonts::Face text_;
  fonts::Face symbols_;
};

}
