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
import telar.wire.vocabulary;
import telar.base.ds;

export {
  namespace telar::gui::inline foundation::inline fonts::tests::font_fixture {

    template <Allocator Memory>
    class FontFixture {
    public:
      // The fixture reads its fonts into memory, region `a`.
      FontFixture(tbc::mut_a<Memory> memory, const std::filesystem::path& directory, const char* primary_filename = "JetBrainsMono-Regular.ttf")
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
      static tbc::val_a<ds::Vec<std::uint8_t, Memory>> read(tbc::mut_a<Memory> memory, const std::filesystem::path& path) {
        const auto data = runtime::readFile(memory, path.c_str(), telar_font_max_bytes);

        return ds::Vec<std::uint8_t, Memory>{memory, telar::byteView({data.data(), data.size()})};
      }

      tbc::val_a<ds::Vec<std::uint8_t, Memory>> regular_bytes_;
      tbc::val_a<ds::Vec<std::uint8_t, Memory>> emphasized_bytes_;
      tbc::val_a<ds::Vec<std::uint8_t, Memory>> primary_bytes_;
      tbc::val_a<ds::Vec<std::uint8_t, Memory>> text_bytes_;
      tbc::val_a<ds::Vec<std::uint8_t, Memory>> symbols_bytes_;
      // The faces read the bytes stored beside them.
      tbc::val_self<fonts::Face> regular_;
      tbc::val_self<fonts::Face> emphasized_;
      tbc::val_self<fonts::Face> primary_;
      tbc::val_self<fonts::Face> text_;
      tbc::val_self<fonts::Face> symbols_;
    };

  }
}
