module;
#include <freetype/freetype.h>
#include <hb.h>

#include "platform/font.h"

export module telar.gui.foundation.fonts:face;

import std;

import telar.tbc;
import telar.gui.foundation.terminal;
import :face_views;
import telar.base.ds;

// Interface: fonts/glyph_bitmap_view.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct GlyphStyle {
      bool bold = false;
      bool italic = false;

      bool operator==(const GlyphStyle&) const = default;
    };

    // How outlines snap to the pixel grid. `native` keeps FreeType's default (the font's own
    // instructions) and, on macOS with thicken, CoreText. `light` aligns horizontal features
    // (baseline, x-height, bars); `full` also aligns stems, through FreeType's autohinter.
    enum class GlyphHinting : std::uint8_t {
      native,
      light,
      full,
    };

    struct GlyphRasterRequest {
      std::uint32_t index = 0;
      std::uint16_t pixel_height = 0;
      GlyphStyle style;
      std::uint8_t thicken_strength = 0;
      GlyphHinting hinting = GlyphHinting::native;
    };

    struct GlyphBitmapView {
      std::span<const std::uint8_t> coverage;
      std::size_t stride = 0;
      std::uint32_t width = 0;
      std::uint32_t height = 0;
      std::int32_t left = 0;
      std::int32_t top = 0;

      [[nodiscard]] std::span<const std::uint8_t> row(std::size_t index) const noexcept;
    };

  }
}

// Interface: fonts/ligature_role.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    enum class LigatureRole : std::uint8_t {
      none,
      context,
      input,
    };

  }
}

// Interface: fonts/ligature_coverage.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    class LigatureCoverage {
    public:
      static constexpr std::size_t ascii_count = 128;

      explicit LigatureCoverage(FT_Face face, hb_font_t* font);
      [[nodiscard]] LigatureRole role(std::string_view text) const noexcept;
      [[nodiscard]] bool joins() const noexcept;
      [[nodiscard]] std::uint16_t reach() const noexcept;

    private:
      struct SetDeleter {
        void operator()(hb_set_t* set) const noexcept;
      };

      using OwnedSet = std::unique_ptr<hb_set_t, SetDeleter>;

      [[nodiscard]] static OwnedSet createSet();
      [[nodiscard]] static std::uint16_t maximumContext(FT_Face face);

      ds::Array<LigatureRole, ascii_count> ascii_{};
      OwnedSet input_;
      OwnedSet context_;
      std::uint16_t reach_ = 0;
    };

  }
}

// Interface: fonts/native_match.cppm
export {
  extern "C" {
  }

  namespace telar::gui::inline foundation::inline fonts {

    using FontMatch = telar_font_match;
    using FontVariation = telar_font_variation;

    [[nodiscard]] bool sameFontMatch(const FontMatch& left, const FontMatch& right) noexcept;

  }
}

// Interface: fonts/face.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    class Face {
    public:
      static constexpr std::size_t maximum_sizes = 8;

      // FreeType reads the bytes for as long as the face exists; the match is copied.
      explicit Face(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> bytes, const FontMatch& match = {});
      ~Face();
      Face(const Face&) = delete;
      Face& operator=(const Face&) = delete;
      Face(Face&&) = delete;
      Face& operator=(Face&&) = delete;

      [[nodiscard]] FontMetrics metrics(std::uint16_t pixel_height);
      [[nodiscard]] ShapedRunView shape(std::string_view text, std::uint16_t pixel_height);
      [[nodiscard]] GlyphBitmapView rasterize(GlyphRasterRequest request);
      [[nodiscard]] bool covers(char32_t scalar) const noexcept;
      [[nodiscard]] FontVariation variation() const;
      [[nodiscard]] std::string_view family() const noexcept;
      [[nodiscard]] std::string_view style() const noexcept;
      [[nodiscard]] bool fixedPitch() const noexcept;
      [[nodiscard]] bool monochrome() const noexcept;
      [[nodiscard]] const LigatureCoverage& ligatures();

    private:
      struct LibraryDeleter {
        void operator()(FT_Library library) const noexcept;
      };

      struct FaceDeleter {
        void operator()(FT_Face face) const noexcept;
      };

      struct ShapingFontDeleter {
        void operator()(hb_font_t* font) const noexcept;
      };

      struct ShapingBufferDeleter {
        void operator()(hb_buffer_t* buffer) const noexcept;
      };

      struct SizeDeleter {
        void operator()(FT_Size size) const noexcept;
      };

      using OwnedSize = std::unique_ptr<std::remove_pointer_t<FT_Size>, SizeDeleter>;

      struct SizeEntry {
        std::uint16_t height = 0;
        OwnedSize handle;
      };

      void selectFace(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> bytes, const FontMatch& match);
      void applyVariation(const FontVariation& variation);
      void initializeShaping();
      [[nodiscard]] OwnedSize createSize(std::uint16_t pixel_height);
      void selectSize(std::uint16_t pixel_height);

      std::unique_ptr<std::remove_pointer_t<FT_Library>, LibraryDeleter> library_;
      tbc::view<std::unique_ptr<std::remove_pointer_t<FT_Face>, FaceDeleter>, tbc::lt::a> face_;
      std::unique_ptr<hb_font_t, ShapingFontDeleter> shaping_font_;
      std::unique_ptr<hb_buffer_t, ShapingBufferDeleter> shaping_buffer_;
      ds::Option<LigatureCoverage> ligatures_;
      // The sizes are FreeType children of this face.
      tbc::view<ds::Array<SizeEntry, maximum_sizes>, tbc::lt::self> sizes_{};
      std::size_t next_size_slot_ = 0;
      std::uint16_t active_height_ = 0;
      // The widest printable ASCII advance in font units, 0 when the face has none.
      FT_Pos ascii_advance_ = 0;
    };

  }
}

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui::inline foundation::inline fonts {
  using ::telar_font_max_axes;
  using ::telar_font_max_bytes;
}
