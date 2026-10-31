#pragma once

#include "core/memory.hpp"
#include "font_coverage.hpp"
#include "font_role.hpp"
#include "font_runs.hpp"
#include "shaped_run_view.hpp"
#include "text/caption_runs.hpp"
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui::fonts {

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

template <Allocator Memory>
class TextLayout {
public:
  explicit TextLayout(Memory &memory)
      : glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}) {}

  [[nodiscard]] std::span<const ShapedGlyph> glyphs() const noexcept {
    return glyphs_;
  }

  [[nodiscard]] std::span<const TextSpan> spans() const noexcept {
    return single_span_ ? std::span{&*single_span_, std::size_t{1}} : std::span<const TextSpan>{spans_};
  }

  [[nodiscard]] std::int32_t advance() const noexcept {
    return advance_;
  }

  template <CascadingFontProvider Fonts>
  void shape(Fonts &fonts, std::string_view text, TextRequest request) {
    clear();
    append(fonts, text, request);
  }

  template <CascadingFontProvider Fonts>
  void shapeCaption(Fonts &fonts, std::string_view text, TextRequest request) {
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
  [[nodiscard]] static std::int32_t measure(Fonts &fonts, std::string_view text, TextRequest request) {
    std::int32_t advance = 0;
    visit(fonts, text, request, [&](FontSpan span) {
      const auto run = fonts.face(span.role.value_or(FontRole::primary)).shape(span.text, request.pixel_height);
      advance = addAdvance(advance, spanAdvance(fonts, span, request, run));
    });

    return advance;
  }

private:
  void clear() {
    glyphs_.clear();
    spans_.clear();
    single_span_.reset();
    advance_ = 0;
  }

  template <CascadingFontProvider Fonts>
  void append(Fonts &fonts, std::string_view text, TextRequest request) {
    visit(fonts, text, request, [&](FontSpan span) {
      const auto role = span.role.value_or(FontRole::primary);
      const auto run = fonts.face(role).shape(span.text, request.pixel_height);
      const auto start = glyphs_.size();
      appendSpan({.first = start, .count = run.size(), .role = role, .offset = advance_, .columns = span.columns});
      glyphs_.resize(start + run.size());
      for (std::size_t index = 0; index < run.size(); ++index) {
        glyphs_[start + index] = run.glyph(index);
      }

      advance_ = addAdvance(advance_, spanAdvance(fonts, span, request, run));
    });
  }

  void appendSpan(TextSpan span) {
    if (spans_.empty() && !single_span_) {
      single_span_ = span;
      return;
    }

    if (single_span_) {
      spans_.push_back(*single_span_);
      single_span_.reset();
    }

    spans_.push_back(span);
  }

  template <CascadingFontProvider Fonts, typename Visitor>
  static void visit(Fonts &fonts, std::string_view text, TextRequest request, Visitor visitor) {
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
  static std::int32_t spanAdvance(Fonts &fonts, FontSpan span, TextRequest request, ShapedRunView run) {
    if (!span.role || !fittedFont(*span.role)) {
      return run.advance();
    }

    const auto width = static_cast<std::int64_t>(fonts.face(FontRole::primary).metrics(request.pixel_height).maximum_advance) * span.columns;

    return addAdvance(0, width);
  }

  static std::int32_t addAdvance(std::int32_t previous, std::int64_t next) {
    const auto total = previous + next;
    if (total < 0 || total > std::numeric_limits<std::int32_t>::max()) {
      throw std::length_error{"TextAdvanceOutOfRange"};
    }

    return static_cast<std::int32_t>(total);
  }

  Vector<ShapedGlyph, Memory> glyphs_;
  Vector<TextSpan, Memory> spans_;
  std::optional<TextSpan> single_span_;
  std::int32_t advance_ = 0;
};

}
