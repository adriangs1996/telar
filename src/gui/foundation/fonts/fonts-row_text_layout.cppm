module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.fonts:row_text_layout;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;
import :glyphs;
import :face_views;
import :face;
import :font_requests;
import :text_runs;
import telar.base.ds;

// Interface: fonts/font_runs.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    template <typename Fonts>
    concept CascadingFontProvider = FontProvider<Fonts> && requires(Fonts& fonts, std::string_view text, FontRole role) {
      { fonts.source(text, role) } -> std::same_as<ds::Option<FontRole>>;
    };

    struct FontSpan {
      std::string_view text;
      ds::Option<FontRole> role = ds::none;
      std::uint32_t columns = 0;
    };

    // Generic over the caller's font provider; walks a text's clusters once per shaped span.
    template <CascadingFontProvider Fonts>
    class TBC_GENERIC FontRuns {
    public:
      inline FontRuns(Fonts& fonts, std::string_view text, FontRole preferred) noexcept
          : fonts_(fonts),
            text_(text),
            cursor_(text),
            preferred_(preferred) {}

      [[nodiscard]] inline ds::Option<FontSpan> next() {
        const auto start = cursor_.position();
        const auto cluster = cursor_.next();
        if (!cluster) {
          return ds::none;
        }

        auto role = fonts_.source(*cluster, preferred_);
        const auto resolved = role.valueOr(FontRole::primary);
        std::uint32_t columns = cursor_.columns();

        if (resolved == preferred_) {
          while (cursor_.position() < text_.size()) {
            auto candidate = cursor_;
            const auto following = candidate.next();
            if (!following) {
              break;
            }

            const auto following_role = fonts_.source(*following, preferred_);
            if (following_role.valueOr(FontRole::primary) != resolved) {
              break;
            }

            if (!following_role) {
              role.reset();
            }

            cursor_ = candidate;
            columns += cursor_.columns();
          }
        }

        return FontSpan{.text = text_.substr(start, cursor_.position() - start), .role = role, .columns = columns};
      }

    private:
      Fonts& fonts_;
      std::string_view text_;
      GraphemeCursor cursor_;
      FontRole preferred_;
    };

  }
}

// Interface: fonts/text_layout.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct TextSpan {
      std::size_t first = 0;
      std::size_t count = 0;
      FontRole role = FontRole::regular;
      std::int32_t offset = 0;
      std::uint32_t columns = 0;
    };

    struct TextRequest {
      std::uint16_t pixel_height = 0;
      FontRole preferred = FontRole::regular;
    };

    // The members generic over the caller's font provider stay here; the rest is instantiated in
    // row_text_layout.cpp.
    template <Allocator Memory>
    class TextLayout {
    public:
      explicit TextLayout(Memory& memory);

      [[nodiscard]] std::span<const ShapedGlyph> glyphs() const noexcept;

      [[nodiscard]] std::span<const TextSpan> spans() const noexcept;

      [[nodiscard]] std::int32_t advance() const noexcept;

      template <CascadingFontProvider Fonts>
      TBC_GENERIC void shape(Fonts& fonts, std::string_view text, TextRequest request) {
        clear();
        append(fonts, text, request);
      }

      template <CascadingFontProvider Fonts>
      TBC_GENERIC void shapeCaption(Fonts& fonts, std::string_view text, TextRequest request) {
        clear();
        CaptionRuns runs{text};

        while (const auto run = runs.next()) {
          const auto before = advance_;

          append(fonts, *run, request);
          if (advance_ <= before) {
            break;
          }
        }
      }

      template <CascadingFontProvider Fonts>
      TBC_GENERIC [[nodiscard]] static std::int32_t measure(Fonts& fonts, std::string_view text, TextRequest request) {
        std::int32_t advance = 0;

        visit(fonts, text, request, [&](FontSpan span) {
          const auto run = fonts.face(span.role.valueOr(FontRole::primary)).shape(span.text, request.pixel_height);

          advance = addAdvance(advance, spanAdvance(fonts, span, request, run.advance()));
        });

        return advance;
      }

    private:
      void clear();

      template <CascadingFontProvider Fonts>
      TBC_GENERIC void append(Fonts& fonts, std::string_view text, TextRequest request) {
        visit(fonts, text, request, [&](FontSpan span) {
          const auto role = span.role.valueOr(FontRole::primary);
          const auto run = fonts.face(role).shape(span.text, request.pixel_height);
          const auto start = glyphs_.size();

          appendSpan({.first = start, .count = run.size(), .role = role, .offset = advance_, .columns = span.columns});
          glyphs_.resize(start + run.size());
          for (std::size_t index = 0; index < run.size(); ++index) {
            glyphs_[start + index] = run.glyph(index);
          }

          advance_ = addAdvance(advance_, spanAdvance(fonts, span, request, run.advance()));
        });
      }

      void appendSpan(TextSpan span);

      template <CascadingFontProvider Fonts, typename Visitor>
      TBC_GENERIC static void visit(Fonts& fonts, std::string_view text, TextRequest request, Visitor visitor) {
        if (request.pixel_height == 0) {
          throw std::invalid_argument{"InvalidTextPixelHeight"};
        }

        if (text.empty()) {
          return;
        }

        if (!fittedFont(request.preferred) && FontCoverage::covers(fonts.face(request.preferred), text)) {
          visitor(FontSpan{.text = text, .role = request.preferred});
          return;
        }

        FontRuns runs{fonts, text, request.preferred};

        while (const auto span = runs.next()) {
          visitor(*span);
        }
      }

      template <CascadingFontProvider Fonts>
      TBC_GENERIC static std::int32_t spanAdvance(Fonts& fonts, FontSpan span, TextRequest request, std::int32_t shaped_advance) {
        if (!span.role || !fittedFont(*span.role)) {
          return shaped_advance;
        }

        const auto width = static_cast<std::int64_t>(fonts.face(FontRole::primary).metrics(request.pixel_height).maximum_advance) * span.columns;

        return addAdvance(0, width);
      }

      static std::int32_t addAdvance(std::int32_t previous, std::int64_t next);

      Vector<ShapedGlyph, Memory> glyphs_;
      Vector<TextSpan, Memory> spans_;
      ds::Option<TextSpan> single_span_;
      std::int32_t advance_ = 0;
    };

    extern template class TextLayout<Memory>;
    extern template class TextLayout<ConcurrentMemory>;

  }
}

// Interface: fonts/cell_text_layout.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    // A cell's text shaped into glyphs, up to the byte capacity its owner gives it.
    template <Allocator Memory>
    class CellTextLayout {
    public:
      static constexpr std::size_t glyphs_per_byte = 4;

      explicit CellTextLayout(Memory& memory, std::size_t maximum_text_bytes);

      // Generic over the caller's font provider, so it stays here; shapes a cell's text whenever it is painted.
      template <CascadingFontProvider Fonts>
      TBC_GENERIC void shape(Fonts& fonts, std::string_view text, const FontGrid& grid) {
        begin(text, grid);
        GraphemeCursor cursor{text};

        while (const auto cluster_text = cursor.next()) {
          const auto role = fonts.source(*cluster_text, FontRole::primary).valueOr(FontRole::primary);

          append(fonts.face(role).shape(*cluster_text, grid.pixel_height), role, grid, cursor.columns());
        }
      }

      [[nodiscard]] std::span<const ShapedGlyph> glyphs(std::uint32_t available_columns) const noexcept;
      [[nodiscard]] std::uint32_t columns() const noexcept;
      [[nodiscard]] std::span<const TextSpan> spans(std::uint32_t available_columns) const noexcept;

    private:
      struct Cluster {
        std::uint32_t columns = 0;
        std::size_t glyph_end = 0;
        std::size_t span_end = 0;
      };

      void begin(std::string_view text, const FontGrid& grid);
      void append(const ShapedRunView& shaped, FontRole role, const FontGrid& grid, std::uint32_t columns);

      Vector<ShapedGlyph, Memory> glyphs_;
      Vector<TextSpan, Memory> spans_;
      Vector<Cluster, Memory> clusters_;
      std::size_t maximum_text_bytes_;
      std::uint32_t columns_ = 0;
    };

    extern template class CellTextLayout<Memory>;
    extern template class CellTextLayout<ConcurrentMemory>;

  }
}

// Interface: fonts/glyph_transform.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct GlyphTransform {
      float x = 0;
      float y = 0;
      float scale = 1;

      [[nodiscard]] static GlyphTransform fit(Rect ink, Rect cell) noexcept;

      [[nodiscard]] Rect map(Rect ink) const noexcept;
    };

  }
}

// Interface: fonts/ink_bounds.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct InkBounds {
      float left = std::numeric_limits<float>::infinity();
      float top = std::numeric_limits<float>::infinity();
      float right = -std::numeric_limits<float>::infinity();
      float bottom = -std::numeric_limits<float>::infinity();

      void include(Rect area) noexcept;

      [[nodiscard]] Rect rect() const noexcept;
    };

  }
}

// Interface: fonts/icon_layout.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct IconGlyph {
      std::uint32_t index = 0;
      FontRole face = FontRole::regular;
      Rect ink;
    };

    struct IconRequest {
      std::uint16_t pixel_height = 0;
      FontRole preferred = FontRole::regular;
    };

    // The members generic over the caller's font provider stay here; the rest is instantiated in
    // row_text_layout.cpp.
    template <Allocator Memory>
    class IconLayout {
    public:
      static constexpr std::size_t maximum_text_bytes = 256;
      static constexpr std::size_t maximum_glyphs = 256;
      static constexpr float size_ratio = 0.85F;
      static constexpr std::uint16_t oversample = 2;
      static constexpr std::uint16_t maximum_pixel_height = 4096;

      explicit IconLayout(Memory& memory);

      [[nodiscard]] std::span<const IconGlyph> glyphs() const noexcept;

      [[nodiscard]] Rect ink() const noexcept;

      template <CascadingFontProvider Fonts>
      TBC_GENERIC void shape(Fonts& fonts, std::string_view text, IconRequest request) {
        if (text.size() > maximum_text_bytes || request.pixel_height == 0 || request.pixel_height > maximum_pixel_height) {
          throw std::invalid_argument{"InvalidIconLayoutRequest"};
        }

        glyphs_.clear();
        FontRuns runs{fonts, text, request.preferred};
        float advance = 0;

        while (const auto span = runs.next()) {
          if (!span->role) {
            throw std::runtime_error{"IconFontUnavailable"};
          }

          advance += appendRun(fonts, span->text, {.role = *span->role, .request = request, .columns = span->columns, .advance = advance});
        }
      }

    private:
      struct Run {
        FontRole role = FontRole::regular;
        IconRequest request;
        std::uint32_t columns = 0;
        float advance = 0;
      };

      template <CascadingFontProvider Fonts>
      TBC_GENERIC float appendRun(Fonts& fonts, std::string_view text, Run run) {
        auto& face = fonts.face(run.role);
        const auto shaped = face.shape(text, run.request.pixel_height);
        const auto start = glyphs_.size();
        std::int64_t pen = 0;

        for (std::size_t index = 0; index < shaped.size(); ++index) {
          const auto glyph = shaped.glyph(index);
          const auto bitmap = face.rasterize({.index = glyph.index, .pixel_height = run.request.pixel_height, .style = {}});
          if (bitmap.width != 0 && bitmap.height != 0) {
            if (glyphs_.size() == maximum_glyphs) {
              throw std::length_error{"IconGlyphLimitExceeded"};
            }

            const auto x = FontMetrics::roundFixed(pen + glyph.x_offset) + bitmap.left;
            const auto y = -FontMetrics::roundFixed(glyph.y_offset) - bitmap.top;

            glyphs_.push_back({.index = glyph.index, .face = run.role, .ink = {.x = static_cast<float>(x), .y = static_cast<float>(y), .width = static_cast<float>(bitmap.width), .height = static_cast<float>(bitmap.height)}});
          }

          pen += glyph.x_advance;
        }

        auto appended = std::span{glyphs_}.subspan(start);

        if (fittedFont(run.role)) {
          const auto metrics = fonts.face(FontRole::primary).metrics(run.request.pixel_height);
          const Rect cell{.y = -static_cast<float>(metrics.ascender), .width = static_cast<float>(metrics.maximum_advance) * static_cast<float>(run.columns), .height = static_cast<float>(metrics.line_height)};

          fitFallback(appended, cell, run.advance);

          return cell.width;
        }

        for (auto& glyph : appended) {
          glyph.ink.x += run.advance;
        }

        return static_cast<float>(FontMetrics::roundFixed(pen));
      }

      static void fitFallback(std::span<IconGlyph> glyphs, Rect cell, float advance);

      Vector<IconGlyph, Memory> glyphs_;
    };

    extern template class IconLayout<Memory>;
    extern template class IconLayout<ConcurrentMemory>;

  }
}

// Interface: fonts/icon_placement.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct IconPlacement {
      Point origin;
      Point ink_origin;
      float scale = 0;

      [[nodiscard]] static IconPlacement resolve(Rect ink, Rect bounds, float requested_side);

      [[nodiscard]] Rect map(Rect glyph) const noexcept;
    };

  }
}

// Interface: fonts/row_text_layout.cppm
export {
  namespace telar::gui::inline foundation::inline fonts {

    struct RowTextRequest {
      std::uint16_t pixel_height = 1;
      std::uint16_t cell_width = 1;
      ds::Option<std::size_t> cursor = ds::none;
      CellSelection selection{};
      std::size_t first_cell = 0;
    };

    struct CellTextRange {
      std::size_t first_span = 0;
      std::size_t span_count = 0;
    };

    // shape and appendAlone, generic over the caller's font provider, run for every painted row
    // and stay here; the rest is instantiated in row_text_layout.cpp.
    template <Allocator Memory>
    class RowTextLayout {
    public:
      explicit RowTextLayout(Memory& memory);

      void resetFont() noexcept;

      [[nodiscard]] std::span<const ShapedGlyph> glyphs() const noexcept;

      [[nodiscard]] std::span<const TextSpan> spans() const noexcept;

      [[nodiscard]] CellTextRange cell(std::size_t column) const noexcept;

      template <CascadingFontProvider Fonts>
      TBC_GENERIC void shape(Fonts& fonts, std::span<const CellValue> cells, RowTextRequest request) {
        if (request.pixel_height == 0 || request.cell_width == 0 || cells.size() > std::numeric_limits<std::uint16_t>::max()) {
          throw std::invalid_argument{"InvalidRowTextRequest"};
        }

        glyphs_.clear();
        spans_.clear();
        cells_.assign(cells.size(), {});
        runs_.reserve(cells.size());
        runs_.clear();
        auto& primary = fonts.face(FontRole::primary);
        if (cached_face_ != &primary || cached_height_ != request.pixel_height) {
          ascii_ = {};
          clusters_ = {};
          // Only the face's identity is kept, never dereferenced.
          cached_face_ = tbc::raw(&primary);
          cached_height_ = request.pixel_height;
        }

        const auto& coverage = primary.ligatures();

        for (std::size_t column = 0; column < cells.size(); ++column) {
          auto projected = cells[column];

          if (request.selection.contains(request.first_cell + column)) {
            projected.style.flags ^= static_cast<std::uint16_t>(CellAttribute::inverse);
          }

          runs_.append(coverage, projected, request.cursor == column);
        }

        runs_.close(coverage.reach());
        for (std::size_t column = 0; column < cells.size();) {
          const auto run = runs_.at(column);
          const auto source = cells.subspan(column, run.count);
          if (!run.together || !appendTogether(primary, source, column, request)) {
            for (std::size_t offset = 0; offset < run.count; ++offset) {
              appendAlone(fonts, source[offset], column + offset, request);
            }
          }

          column += run.count;
        }
      }

    private:
      [[nodiscard]] static std::int32_t cellOffset(std::size_t column, RowTextRequest request);

      void appendPrimary(std::span<const ShapedGlyph> glyphs, std::size_t column, RowTextRequest request);

      bool appendTogether(Face& face, std::span<const CellValue> cells, std::size_t column, RowTextRequest request);

      template <CascadingFontProvider Fonts>
      TBC_GENERIC void appendAlone(Fonts& fonts, const CellValue& cell, std::size_t column, RowTextRequest request) {
        if (cell.width == CellWidth::continuation || hasAttribute(cell.style, CellAttribute::invisible) || glyphs::Symbol::parse(cell.utf8()) || cell.utf8().starts_with(placeholder_prefix)) {
          return;
        }

        const auto text = cell.utf8();
        auto& face = fonts.face(FontRole::primary);

        if (text.size() == 1 && static_cast<unsigned char>(text.front()) < ascii_.size()) {
          auto& cached = ascii_.atMut(static_cast<unsigned char>(text.front()));
          if (cached) {
            appendPrimary(std::span{&*cached, std::size_t{1}}, column, request);
            return;
          }

          if (FontCoverage::covers(face, text)) {
            const auto shaped = face.shape(text, request.pixel_height);
            if (shaped.size() == 1) {
              cached = shaped.glyph(0);
              appendPrimary(std::span{&*cached, std::size_t{1}}, column, request);
              return;
            }
          }
        }

        // A short cell outside ASCII that the primary face covers shapes as one span of it, which
        // a cell repeats on every row painted again: kept as that span's single glyph.
        static_assert(!fittedFont(FontRole::primary));
        const auto key = clusterKey(text);
        auto* entry = key != 0 ? &clusters_.atMut(clusterSlot(key)) : nullptr;
        if (entry != nullptr && entry->key != key) {
          *entry = {.key = key};
          if (FontCoverage::covers(face, text)) {
            const auto shaped = face.shape(text, request.pixel_height);

            entry->single = shaped.size() == 1;
            entry->glyph = entry->single ? shaped.glyph(0) : ShapedGlyph{};
          }
        }

        // A text kept as not one glyph of the primary face takes the general route without asking
        // the face again.
        if (entry != nullptr && entry->single) {
          appendCluster(entry->glyph, column, request);
          return;
        }

        cell_.shape(fonts, text, {.pixel_height = request.pixel_height, .preferred = FontRole::primary});
        const auto first_glyph = glyphs_.size();

        glyphs_.insert(glyphs_.end(), cell_.glyphs().begin(), cell_.glyphs().end());
        cells_[column] = {.first_span = spans_.size(), .span_count = cell_.spans().size()};
        for (auto span : cell_.spans()) {
          span.first += first_glyph;
          const auto offset = static_cast<std::int64_t>(span.offset) + cellOffset(column, request);
          if (offset > std::numeric_limits<std::int32_t>::max()) {
            throw std::length_error{"CellTextOffsetOutOfRange"};
          }

          span.offset = static_cast<std::int32_t>(offset);
          spans_.push_back(span);
        }
      }

      // The bytes of a cell of two to four, with its length in the top byte: never zero.
      [[nodiscard]] static std::uint64_t clusterKey(std::string_view text) noexcept;

      // Fibonacci hashing: the top bits of the key times 2^64 over the golden ratio.
      [[nodiscard]] static std::size_t clusterSlot(std::uint64_t key) noexcept;

      // What TextLayout makes of a text the primary face covers: one span of its glyphs, starting
      // at the cell, with no columns of a fitted face.
      void appendCluster(ShapedGlyph glyph, std::size_t column, RowTextRequest request);

      struct Cluster {
        std::uint64_t key = 0;
        ShapedGlyph glyph{};
        // Whether the primary face covers the text as one glyph; otherwise glyph is unused.
        bool single = false;
      };

      static constexpr unsigned cluster_bits = 8;
      static constexpr unsigned cluster_length_shift = 56U;
      static constexpr std::uint64_t golden_ratio_multiplier = 0x9e3779b97f4a7c15ULL;

      TextRuns<Memory> runs_;
      TextLayout<Memory> cell_;
      Vector<ShapedGlyph, Memory> glyphs_;
      Vector<TextSpan, Memory> spans_;
      Vector<CellTextRange, Memory> cells_;
      ds::Array<ds::Option<ShapedGlyph>, LigatureCoverage::ascii_count> ascii_{};
      ds::Array<Cluster, std::size_t{1} << cluster_bits> clusters_{};
      const Face* cached_face_ = nullptr;
      std::uint16_t cached_height_ = 0;
    };

    extern template class RowTextLayout<Memory>;
    extern template class RowTextLayout<ConcurrentMemory>;

  }
}
