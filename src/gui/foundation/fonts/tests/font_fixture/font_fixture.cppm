module;
#include "platform/font.h"
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <freetype/freetype.h>
#include <hb.h>
#include <sys/stat.h>

export module telar.gui.foundation.fonts.tests.font_fixture;

import std;
import telar.tbc;
import telar.gui.foundation.core;
import telar.base.memory.allocators;
import telar.gui.foundation.fonts;
import telar.platform.fs;
import telar.base.ds;

export {
  namespace telar::gui::inline foundation::inline fonts::tests::font_fixture {

    template <Allocator Memory>
    class FontFixture {
    public:
      // The fixture reads its fonts into memory, region `a`.
      FontFixture(tbc::view<Memory&, tbc::lt::a> memory, const std::filesystem::path& directory, const char* primary_filename = "JetBrainsMono-Regular.ttf")
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

      [[nodiscard]] fonts::Face& face(fonts::FontRole role) {
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

      [[nodiscard]] ds::Option<fonts::FontRole> source(std::string_view text, fonts::FontRole preferred) {
        return fonts::FontCascade::source(*this, text, preferred);
      }

    private:
      // The bytes are storage of the allocator, region `a`.
      static tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> read(tbc::view<Memory&, tbc::lt::a> memory, const std::filesystem::path& path) {
        const auto data = runtime::readFile(memory, path.c_str(), telar_font_max_bytes);

        return {data.cbegin(), data.cend(), AllocatorRef<std::uint8_t, Memory>{memory}};
      }

      tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> regular_bytes_;
      tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> emphasized_bytes_;
      tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> primary_bytes_;
      tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> text_bytes_;
      tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> symbols_bytes_;
      // The faces read the bytes stored beside them.
      tbc::view<fonts::Face, tbc::lt::self> regular_;
      tbc::view<fonts::Face, tbc::lt::self> emphasized_;
      tbc::view<fonts::Face, tbc::lt::self> primary_;
      tbc::view<fonts::Face, tbc::lt::self> text_;
      tbc::view<fonts::Face, tbc::lt::self> symbols_;
    };

  }
}
