#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "chrome_text_scene.hpp"
#include "alpha_mask.hpp"
#include "alpha_mask_material.hpp"
#include "alpha_mask_vertex.hpp"
#include "chrome_glyph_images.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include <cmath>
#include "font_collection.hpp"
#include <concepts>
#include <utility>
#include <limits>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <stdexcept>
#include <hb.h>
#include <span>
#include "../core/memory.hpp"
#include <bit>
#include <freetype/freetype.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <type_traits>
#include <ghostty/vt/unicode.h>
#include "resident_fonts.hpp"
#include "scene_nodes.hpp"
#include <QColor>
#include <QImage>
#include <QList>
#include <QMatrix4x4>
#include <QPointF>
#include <QQuickWindow>
#include <QRectF>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSGImageNode>
#include <QSGNode>
#include <QSGOpacityNode>
#include <QSGTexture>
#include <QSGTransformNode>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <QtCore/qtversion.h>
#include <QtCore/qtversionchecks.h>
#include <initializer_list>
#include "tbc/view.hpp"



import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.fonts.font_requests;
import telar.gui.fonts.row_text_layout;
import telar.gui.terminal.font_grid;

namespace telar::gui::qt {
namespace {

constexpr std::int64_t fixed_unit = 64;

struct TextOrigin {
  std::int64_t fixed_x = 0;
  float baseline = 0;
  float x = 0;
};

struct GlyphPlacement {
  fonts::ShapedGlyph glyph;
  AlphaMaskRef mask;
  std::int64_t advance_before = 0;
  fonts::GlyphTransform transform;
  fonts::FontRole role = fonts::FontRole::regular;
  std::int32_t run_offset = 0;
  std::int32_t left = 0;
  std::int32_t top = 0;

  [[nodiscard]] Rect bounds(TextOrigin origin) const {
    const auto natural = !fonts::fittedFont(role);
    const auto run_origin = origin.fixed_x + (static_cast<std::int64_t>(run_offset) * fixed_unit);
    const auto x = static_cast<std::int64_t>(FontMetrics::roundFixed((natural ? run_origin : 0) + advance_before + glyph.x_offset)) + left;
    const auto y = -FontMetrics::roundFixed(glyph.y_offset) - top;
    const auto width = static_cast<float>(mask->alpha.width());
    const auto height = static_cast<float>(mask->alpha.height());
    if (natural) {
      return {.x = static_cast<float>(x), .y = std::round(origin.baseline) + static_cast<float>(y), .width = width, .height = height};
    }

    return {.x = origin.x + static_cast<float>(run_offset) + (static_cast<float>(x) * transform.scale) + transform.x, .y = origin.baseline + (static_cast<float>(y) * transform.scale) + transform.y, .width = width * transform.scale, .height = height * transform.scale};
  }
};

struct MaskQuad {
  QRectF bounds;
  QRectF source;
  float opacity = 0;
};

enum class MaskSampling : unsigned char {
  continuous,
  pixel_centers,
};

struct TextProjection {
  TextOrigin origin;
  QPointF anchor;
  Rect area;
  float fade_width = 0;
  qreal scale = 1;

  [[nodiscard]] MaskQuad quad(const GlyphPlacement &placed, MaskSampling sampling = MaskSampling::continuous) const {
    const auto full = placed.bounds(origin);
    auto clipped = full.intersect(area);
    if (clipped.empty()) {
      return {};
    }

    float opacity = 1;
    if (fade_width > 0) {
      const auto start = std::max(area.x, area.right() - fade_width);
      const auto span = area.right() - start;
      const auto center = clipped.x + (clipped.width / 2);
      opacity = span == 0 ? static_cast<float>(center < area.right()) : std::clamp((area.right() - center) / span, 0.0F, 1.0F);
    }

    if (sampling == MaskSampling::pixel_centers) {
      constexpr float pixel_center = 0.5F;
      const auto right = std::ceil(clipped.right() - pixel_center);
      const auto bottom = std::ceil(clipped.bottom() - pixel_center);
      clipped.x = std::ceil(clipped.x - pixel_center);
      clipped.y = std::ceil(clipped.y - pixel_center);
      clipped.width = std::max(0.0F, right - clipped.x);
      clipped.height = std::max(0.0F, bottom - clipped.y);
    }

    return {
        .bounds = {
            (clipped.x - anchor.x()) / scale,
            (clipped.y - anchor.y()) / scale,
            clipped.width / scale,
            clipped.height / scale,
        },
        .source = {
            (clipped.x - full.x) / full.width,
            (clipped.y - full.y) / full.height,
            clipped.width / full.width,
            clipped.height / full.height,
        },
        .opacity = opacity,
    };
  }
};

void validateCoordinates(std::initializer_list<float> coordinates) {
  constexpr auto maximum_coordinate = static_cast<double>(std::numeric_limits<std::int32_t>::max()) / 2;
  if (std::ranges::any_of(coordinates, [](float value) {
        return !std::isfinite(value) || std::abs(value) > maximum_coordinate;
      })) {
    throw std::out_of_range{"ChromeTextBoundsOutOfRange"};
  }
}

TextProjection projection(const ChromeTextPaint &paint) {
  if (!std::isfinite(paint.scale) || paint.scale <= 0) {
    throw std::invalid_argument{"InvalidChromeTextScale"};
  }

  if (paint.placement) {
    const auto &placement = *paint.placement;
    const auto x = static_cast<float>(placement.origin.x() * paint.scale);
    const auto y = static_cast<float>((placement.origin.y() + placement.baseline) * paint.scale);
    const auto &clip = placement.clip;
    const Rect area{.x = static_cast<float>(clip.x() * paint.scale), .y = static_cast<float>(clip.y() * paint.scale), .width = static_cast<float>(clip.width() * paint.scale), .height = static_cast<float>(clip.height() * paint.scale)};
    validateCoordinates({x, y, area.x, area.y, area.width, area.height});

    return {.origin = {.fixed_x = static_cast<std::int64_t>(std::round(x * fixed_unit)), .baseline = y, .x = x}, .anchor = {}, .area = area, .scale = paint.scale};
  }

  const auto raw_x = static_cast<float>(paint.scene_origin.x() * paint.scale);
  const auto raw_y = static_cast<float>(paint.scene_origin.y() * paint.scale);
  const auto width = static_cast<float>(paint.bounds.width() * paint.scale);
  const auto height = static_cast<float>(paint.bounds.height() * paint.scale);
  validateCoordinates({raw_x, raw_y, width, height});

  auto x = raw_x;
  if (paint.horizontal_alignment.testFlag(Qt::AlignHCenter)) {
    const auto inset = std::max(0.0F, width - static_cast<float>(paint.advance)) / 2;
    x += paint.whole_pixel_centering ? std::floor(inset) : inset;
  } else if (paint.horizontal_alignment.testFlag(Qt::AlignRight)) {
    x += std::max(0.0F, width - static_cast<float>(paint.advance));
  }

  const auto line_height = paint.grid ? static_cast<float>(paint.grid->height) : static_cast<float>(paint.metrics.line_height);
  const auto ascender = paint.grid ? paint.grid->baseline : static_cast<float>(paint.metrics.ascender);
  const auto line_baseline = std::floor(raw_y + ((height - line_height) / 2)) + ascender;
  const auto baseline = paint.grid ? std::round(line_baseline) : line_baseline;

  return {.origin = {.fixed_x = static_cast<std::int64_t>(std::round(x * fixed_unit)), .baseline = baseline, .x = x}, .anchor = {std::floor(raw_x), std::floor(raw_y)}, .area = {.x = raw_x, .y = raw_y, .width = width, .height = height}, .fade_width = static_cast<float>(paint.fade_width * paint.scale), .scale = paint.scale};
}

Color ink(const ChromeTextPaint &paint) noexcept {
  if (paint.foreground) {
    return *paint.foreground;
  }

  const auto &color = paint.color;

  return {.r = color.redF(), .g = color.greenF(), .b = color.blueF(), .a = color.alphaF()};
}

class GlyphMesh final : public QSGGeometryNode {
public:
  GlyphMesh(QList<GlyphPlacement> glyphs, Color foreground, AlphaMaskSampling sampling, AlphaMaskBlend blend, MaskSampling placement)
      : glyphs_(std::move(glyphs)),
        geometry_(alphaMaskAttributes(), static_cast<int>(static_cast<std::size_t>(glyphs_.size()) * alpha_mask_triangle_vertices)),
        material_(*glyphs_.front().mask->texture, foreground, sampling, blend),
        sampling_(sampling),
        blend_(blend),
        placement_(placement),
        capacity_(geometry_.vertexCount()) {
    geometry_.setDrawingMode(QSGGeometry::DrawTriangles);
    setGeometry(&geometry_);
    setMaterial(&material_);
  }

  [[nodiscard]] bool accepts(const QList<GlyphPlacement> &glyphs, AlphaMaskSampling sampling, AlphaMaskBlend blend, MaskSampling placement) const noexcept {
    return sampling_ == sampling && blend_ == blend && placement_ == placement && material_.texture().comparisonKey() == glyphs.front().mask->texture->comparisonKey();
  }

  void replace(QList<GlyphPlacement> &glyphs) {
    constexpr auto maximum_glyphs = std::numeric_limits<int>::max() / alpha_mask_triangle_vertices;
    if (std::cmp_greater(glyphs.size(), maximum_glyphs)) {
      throw std::length_error{"GlyphMeshTooLarge"};
    }

    glyphs_.swap(glyphs);
    const auto vertices = static_cast<int>(static_cast<std::size_t>(glyphs_.size()) * alpha_mask_triangle_vertices);
    if (vertices > capacity_) {
      geometry_.allocate(vertices);
      capacity_ = vertices;
    } else {
#if QT_VERSION >= QT_VERSION_CHECK(6, 10, 0)
      geometry_.setVertexCount(vertices);
#else
      geometry_.allocate(vertices);
      capacity_ = vertices;
#endif
    }
  }

  void paint(const TextProjection &position, Color foreground) {
    auto *vertices = static_cast<AlphaMaskVertex *>(geometry_.vertexData());
    std::size_t offset = 0;
    for (const auto &glyph : glyphs_) {
      const auto quad = position.quad(glyph, placement_);
      const auto atlas = glyph.mask->texture->normalizedTextureSubRect();
      const QRectF source{atlas.x() + (quad.source.x() * atlas.width()), atlas.y() + (quad.source.y() * atlas.height()), quad.source.width() * atlas.width(), quad.source.height() * atlas.height()};
      writeAlphaMaskQuad(std::span<AlphaMaskVertex, alpha_mask_triangle_vertices>{vertices + offset, alpha_mask_triangle_vertices}, quad.bounds, source, quad.opacity);
      offset += alpha_mask_triangle_vertices;
    }

    material_.setForeground(foreground);
    markDirty(DirtyGeometry | DirtyMaterial);
  }

private:
  QList<GlyphPlacement> glyphs_;
  QSGGeometry geometry_;
  AlphaMaskMaterial material_;
  AlphaMaskSampling sampling_ = AlphaMaskSampling::standard;
  AlphaMaskBlend blend_ = AlphaMaskBlend::premultiplied;
  MaskSampling placement_ = MaskSampling::continuous;
  int capacity_ = 0;
};

template <fonts::FontProvider FontSet, bool optical>
class SoftwareGlyph final : public QSGOpacityNode {
public:
  SoftwareGlyph(QQuickWindow &window, GlyphPlacement placed)
      : placed_(std::move(placed)),
        image_(adoptSceneNode(*this, createSceneImage(window))) {
    image_.setFiltering(QSGTexture::Nearest);
  }

  ~SoftwareGlyph() override {
    clearSceneChildren(*this);
  }

  SoftwareGlyph(const SoftwareGlyph &) = delete;
  SoftwareGlyph &operator=(const SoftwareGlyph &) = delete;
  SoftwareGlyph(SoftwareGlyph &&) = delete;
  SoftwareGlyph &operator=(SoftwareGlyph &&) = delete;

  void paint(ChromeGlyphImages<FontSet, optical> &images, const ChromeTextPaint &paint, const TextProjection &position) {
    auto colored = images.colored(placed_.glyph.index, paint.pixel_height, placed_.role, paint.style, paint.color);
    const auto quad = position.quad(placed_, MaskSampling::pixel_centers);
    image_.setTexture(colored->texture.get());
    colored_ = std::move(colored);
    image_.setRect(quad.bounds);
    image_.setSourceRect({quad.source.x() * placed_.mask->alpha.width(), quad.source.y() * placed_.mask->alpha.height(), quad.source.width() * placed_.mask->alpha.width(), quad.source.height() * placed_.mask->alpha.height()});
    setOpacity(quad.opacity);
  }

private:
  GlyphPlacement placed_;
  tbc::view<QSGImageNode &, tbc::lt::self> image_;
  AlphaMaskRef colored_;
};

struct RetainedGlyphMeshes {
  fonts::GlyphRasterization rasterization;
  QList<GlyphPlacement> group;
  qsizetype next_mesh = 0;
};

struct TransientGlyphMeshes {};

template <fonts::FontProvider FontSet, bool retain_meshes>
class ChromeScene final : public QSGTransformNode {
public:
  ChromeScene(QQuickWindow &window, std::shared_ptr<FontSet> fonts, fonts::GlyphRasterization rasterization)
      : window_(window),
        fonts_(std::move(fonts)),
        images_(ChromeGlyphImages<FontSet, retain_meshes>::shared(window, fonts_, rasterization)) {
    if constexpr (retain_meshes) {
      retained_.rasterization = rasterization;
    }
  }

  [[nodiscard]] fonts::GlyphRasterization rasterization() const noexcept {
    if constexpr (retain_meshes) {
      return retained_.rasterization;
    } else {
      return {};
    }
  }

  [[nodiscard]] const FontSet *fonts() const noexcept {
    return fonts_.get();
  }

  void paint(const ChromeTextPaint &paint) {
    if (revision_ != paint.revision) {
      rebuild(paint);
      revision_ = paint.revision;
    }

    const auto position = projection(paint);
    QMatrix4x4 transform;
    transform.translate(static_cast<float>((position.anchor.x() / paint.scale) - paint.scene_origin.x()), static_cast<float>((position.anchor.y() / paint.scale) - paint.scene_origin.y()));
    setMatrix(transform);
    for (auto *mesh : meshes_) {
      mesh->paint(position, ink(paint));
    }

    for (auto *glyph : software_glyphs_) {
      glyph->paint(*images_, paint, position);
    }
  }

private:
  void appendMesh(QList<GlyphPlacement> &glyphs, const ChromeTextPaint &paint) {
    const auto fitted = std::ranges::any_of(glyphs, [](const auto &glyph) {
      return fonts::fittedFont(glyph.role);
    });
    const auto sampling = AlphaMaskSampling::standard;
    const auto blend = paint.foreground ? AlphaMaskBlend::straight : AlphaMaskBlend::premultiplied;
    const auto placement = fitted ? MaskSampling::pixel_centers : MaskSampling::continuous;
    if constexpr (retain_meshes) {
      const auto index = retained_.next_mesh++;
      if (index < meshes_.size() && meshes_[index]->accepts(glyphs, sampling, blend, placement)) {
        meshes_[index]->replace(glyphs);
      } else {
        auto mesh = std::make_unique<GlyphMesh>(std::move(glyphs), ink(paint), sampling, blend, placement);
        if (index < meshes_.size()) {
          const std::unique_ptr<GlyphMesh> previous{meshes_[index]};
          insertChildNodeBefore(mesh.get(), previous.get());
          meshes_[index] = mesh.release();
        } else {
          meshes_.append(&adoptSceneNode(*this, std::move(mesh)));
        }
      }
    } else {
      auto mesh = std::make_unique<GlyphMesh>(std::move(glyphs), ink(paint), sampling, blend, placement);
      meshes_.append(&adoptSceneNode(*this, std::move(mesh)));
    }
  }

  void rebuild(const ChromeTextPaint &paint) {
    if (!retain_meshes || images_->software()) {
      clearSceneChildren(*this);
      meshes_.clear();
      software_glyphs_.clear();
    }

    if constexpr (retain_meshes) {
      retained_.next_mesh = 0;
      auto group = std::move(retained_.group);
      group.clear();
      rebuildGroups(paint, group);
      retained_.group = std::move(group);
      while (meshes_.size() > retained_.next_mesh) {
        const std::unique_ptr<GlyphMesh> discarded{meshes_.takeLast()};
      }
    } else {
      QList<GlyphPlacement> group;
      rebuildGroups(paint, group);
    }
  }

  void rebuildGroups(const ChromeTextPaint &paint, QList<GlyphPlacement> &group) {
    if (!images_->software()) {
      group.reserve(static_cast<qsizetype>(paint.glyphs.size()));
    }

    if (paint.spans.empty()) {
      appendSpan({.count = paint.glyphs.size(), .role = paint.emphasized ? fonts::FontRole::emphasized : paint.role}, paint, group);
    } else {
      for (const auto &span : paint.spans) {
        appendSpan(span, paint, group);
      }
    }

    if (!group.empty()) {
      appendMesh(group, paint);
    }
  }

  [[nodiscard]] fonts::GlyphTransform spanTransform(const fonts::TextSpan &span, const ChromeTextPaint &paint) {
    if (!fonts::fittedFont(span.role)) {
      return {};
    }

    fonts::InkBounds bounds;
    std::int64_t advance = 0;
    for (const auto &glyph : paint.glyphs.subspan(span.first, span.count)) {
      const auto &image = images_->glyph(glyph.index, paint.pixel_height, span.role, paint.style);
      if (!image.mask->alpha.isNull()) {
        const auto x = FontMetrics::roundFixed(advance + glyph.x_offset) + image.left;
        const auto y = -FontMetrics::roundFixed(glyph.y_offset) - image.top;
        bounds.include({.x = static_cast<float>(x), .y = static_cast<float>(y), .width = static_cast<float>(image.mask->alpha.width()), .height = static_cast<float>(image.mask->alpha.height())});
      }

      advance += glyph.x_advance;
    }

    const auto metrics = fonts_->face(fonts::FontRole::primary).metrics(paint.pixel_height);
    const Rect cell{.y = paint.grid ? -paint.grid->baseline : -static_cast<float>(metrics.ascender), .width = static_cast<float>(paint.grid ? paint.grid->width : metrics.maximum_advance) * static_cast<float>(span.columns), .height = static_cast<float>(paint.grid ? paint.grid->height : metrics.line_height)};

    return fonts::GlyphTransform::fit(bounds.rect(), cell);
  }

  void appendSpan(const fonts::TextSpan &span, const ChromeTextPaint &paint, QList<GlyphPlacement> &group) {
    const auto transform = spanTransform(span, paint);
    std::int64_t advance = 0;
    for (const auto &glyph : paint.glyphs.subspan(span.first, span.count)) {
      const auto &image = images_->glyph(glyph.index, paint.pixel_height, span.role, paint.style);
      GlyphPlacement placed{.glyph = glyph, .mask = image.mask, .advance_before = advance, .transform = transform, .role = span.role, .run_offset = span.offset, .left = image.left, .top = image.top};
      advance += glyph.x_advance;
      if (image.mask->alpha.isNull()) {
        continue;
      }

      if (images_->software()) {
        auto node = std::make_unique<SoftwareGlyph<FontSet, retain_meshes>>(window_, std::move(placed));
        node->paint(*images_, paint, projection(paint));
        software_glyphs_.append(&adoptSceneNode(*this, std::move(node)));
      } else {
        if (!group.empty() && group.front().mask->texture->comparisonKey() != image.mask->texture->comparisonKey()) {
          appendMesh(group, paint);
          group.clear();
        }

        group.append(std::move(placed));
      }
    }
  }

  QQuickWindow &window_;
  std::shared_ptr<FontSet> fonts_;
  std::shared_ptr<ChromeGlyphImages<FontSet, retain_meshes>> images_;
  // The meshes and software glyphs are this node's children.
  tbc::view<QList<GlyphMesh *>, tbc::lt::self> meshes_;
  tbc::view<QList<SoftwareGlyph<FontSet, retain_meshes> *>, tbc::lt::self> software_glyphs_;
  std::uint64_t revision_ = 0;
  [[no_unique_address]] std::conditional_t<retain_meshes, RetainedGlyphMeshes, TransientGlyphMeshes> retained_;
};

}

namespace {

// The node painted is the previous one again or a new one Qt takes: region `a`.
template <bool retain_meshes>
tbc::view<QSGNode *, tbc::lt::a> paintText(tbc::view<QSGNode *, tbc::lt::a> previous, QQuickWindow &window, const ChromeTextPaint &paint, const std::shared_ptr<const FontCollection> &collection, fonts::GlyphRasterization rasterization) {
  std::unique_ptr<QSGNode> owner{previous};
  auto fonts = ResidentFonts::shared(collection);
  auto *scene = dynamic_cast<ChromeScene<ResidentFonts, retain_meshes> *>(owner.get());
  if (scene == nullptr || scene->fonts() != fonts.get() || (retain_meshes && scene->rasterization() != rasterization)) {
    auto replacement = std::make_unique<ChromeScene<ResidentFonts, retain_meshes>>(window, std::move(fonts), rasterization);
    scene = replacement.get();
    owner = std::move(replacement);
  }

  scene->paint(paint);

  return owner.release();
}

}

QSGNode *paintChromeText(QSGNode *previous, QQuickWindow &window, const ChromeTextPaint &paint, const std::shared_ptr<const FontCollection> &collection) {
  return paintText<false>(previous, window, paint, collection, fonts::GlyphRasterization{});
}

QSGNode *paintTerminalText(QSGNode *previous, QQuickWindow &window, const ChromeTextPaint &paint, const std::shared_ptr<const FontCollection> &collection, fonts::GlyphRasterization rasterization) {
  if (rasterization.optical) {
    return paintText<true>(previous, window, paint, collection, rasterization);
  }

  return paintText<false>(previous, window, paint, collection, fonts::GlyphRasterization{});
}

}
