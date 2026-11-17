export module telar.gui.foundation.fonts:glyph_rasterizer;

import std;

import :face;

// The native rasterizer behind the C ABI of platform/macos/glyph_rasterizer.h; importers only
// hold a pointer to it.
extern "C" {
struct telar_glyph_rasterizer;
}

export {
  namespace telar::gui::inline foundation::inline fonts {

    class GlyphRasterizer final {
    public:
      GlyphRasterizer(std::span<std::uint8_t> pixels, std::span<const std::uint8_t> bytes, const fonts::FontMatch& match, std::uint8_t strength);
      ~GlyphRasterizer();
      GlyphRasterizer(const GlyphRasterizer&) = delete;
      GlyphRasterizer& operator=(const GlyphRasterizer&) = delete;
      GlyphRasterizer(GlyphRasterizer&&) = delete;
      GlyphRasterizer& operator=(GlyphRasterizer&&) = delete;

      [[nodiscard]] fonts::GlyphBitmapView rasterize(fonts::GlyphRasterRequest request);
      [[nodiscard]] static std::size_t requiredBytes() noexcept;

    private:
      struct Deleter {
        void operator()(telar_glyph_rasterizer* rasterizer) const noexcept;
      };

      std::span<std::uint8_t> pixels_;
      std::unique_ptr<telar_glyph_rasterizer, Deleter> rasterizer_;
    };

  }
}
