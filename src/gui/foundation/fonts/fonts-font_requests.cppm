export module telar.gui.foundation.fonts:font_requests;

import std;

import :face_views;
import :face;
import telar.base.ds;

// Interface: fonts/font_coverage.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct FontCoverage {
      [[nodiscard]] static bool covers(const Face& face, std::string_view text);

      [[nodiscard]] static bool isSelectorOrJoiner(std::uint32_t codepoint) noexcept;
    };

  }
}

// Interface: fonts/font_cascade.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct FontCascade {
      // Generic over the caller's font provider; asked once per text run that needs a face.
      template <FontProvider Fonts>
      [[tbc::generic]] [[nodiscard]] static ds::Option<FontRole> source(Fonts& fonts, std::string_view text, FontRole preferred) {
        if (FontCoverage::covers(fonts.face(preferred), text)) {
          return preferred;
        }

        constexpr ds::Array fallback{FontRole::primary, FontRole::text, FontRole::symbols};

        for (const auto role : fallback) {
          if (FontCoverage::covers(fonts.face(role), text)) {
            return role;
          }
        }

        if constexpr (requires { fonts.fallbackCount(); }) {
          for (std::size_t index = 0; index < fonts.fallbackCount(); ++index) {
            const auto role = fallbackRole(index);
            if (FontCoverage::covers(fonts.face(role), text)) {
              return role;
            }
          }
        }

        return ds::none;
      }
    };

  }
}

// Interface: fonts/font_query.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    class FontQuery {
    public:
      static constexpr std::size_t maximum_bytes = 64;

      [[nodiscard]] static ds::Option<FontQuery> create(std::string_view text);

      [[nodiscard]] std::string_view text() const noexcept;

      [[nodiscard]] const char* codepoints() const noexcept;

    private:
      ds::Array<char, maximum_bytes> text_{};
      ds::Array<char, maximum_bytes + 1> codepoints_{};
      std::uint8_t text_length_ = 0;
      std::uint8_t query_length_ = 0;
    };

  }
}

// Interface: fonts/font_requests.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    class FontRequests {
    public:
      static constexpr std::size_t pending_capacity = 16;
      static constexpr unsigned maximum_retries = 4;

      void request(std::string_view text);

      [[nodiscard]] ds::Option<FontQuery> take();

      [[nodiscard]] bool finish(const FontQuery& query, bool changed);

    private:
      class Misses {
      public:
        [[nodiscard]] bool contains(std::string_view text) const;

        void remember(std::string_view text);

      private:
        static constexpr std::size_t capacity = 4096;
        static constexpr std::size_t ways = 8;
        static constexpr std::size_t sets = capacity / ways;

        static std::uint64_t digest(std::string_view text);

        [[nodiscard]] std::span<std::uint64_t> bucketMut(std::uint64_t hash) noexcept;

        [[nodiscard]] std::span<const std::uint64_t> bucket(std::uint64_t hash) const noexcept;

        ds::Array<std::uint64_t, capacity> hashes_{};
        ds::Array<std::size_t, sets> next_{};
      };

      [[nodiscard]] bool queued(std::string_view text) const;

      ds::Array<FontQuery, pending_capacity> pending_{};
      ds::Option<FontQuery> in_flight_;
      Misses misses_;
      std::size_t head_ = 0;
      std::size_t count_ = 0;
      unsigned retries_ = 0;
      bool turned_away_ = false;
    };

  }
}

// Interface: fonts/glyph_rasterization.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct GlyphRasterization {
      bool optical = false;
      std::uint8_t strength = std::numeric_limits<std::uint8_t>::max();
      GlyphHinting hinting = GlyphHinting::native;

      // Thickening or grid fitting needs its own glyph cache; the default shares the plain one.
      [[nodiscard]] constexpr bool configured() const noexcept {
        return optical || hinting != GlyphHinting::native;
      }

      // macOS draws thickened glyphs with CoreText unless a grid-fitting hinting is chosen.
      [[nodiscard]] constexpr bool coreText() const noexcept {
        return optical && hinting == GlyphHinting::native;
      }

      [[nodiscard]] constexpr std::uint32_t key() const noexcept {
        constexpr unsigned optical_shift = std::numeric_limits<std::uint8_t>::digits;
        constexpr unsigned hinting_shift = optical_shift + 1;
        const auto thickened = optical ? (1U << optical_shift) | strength : 0U;

        return thickened | (static_cast<std::uint32_t>(hinting) << hinting_shift);
      }

      bool operator==(const GlyphRasterization&) const = default;
    };

  }
}
