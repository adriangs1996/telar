#pragma once

#include "core/memory.hpp"
#include "fonts/face.hpp"
#include "fonts/font_cascade.hpp"
#include "fonts/font_role.hpp"
#include "platform/font.h"
#include "telar_platform/read_file.hpp"
#include <cstdint>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string_view>

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
  static Vector<std::uint8_t, Memory> read(Memory &memory, const std::filesystem::path &path) {
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
