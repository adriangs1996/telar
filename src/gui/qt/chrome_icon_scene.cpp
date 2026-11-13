#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "chrome_icon_scene.hpp"
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
#include "font_asset.hpp"
#include "../core/memory.hpp"
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <concepts>
#include <utility>
#include <bit>
#include <ghostty/vt/unicode.h>
#include "resident_fonts.hpp"
#include "scene_nodes.hpp"
#include <QColor>
#include <QList>
#include <QMatrix4x4>
#include <QPointF>
#include <QQuickWindow>
#include <QRectF>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSGImageNode>
#include <QSGNode>
#include <QSGTexture>
#include <QtCore/qtypes.h>



import telar.gui.core.metrics;
import telar.gui.fonts.row_text_layout;

namespace telar::gui::qt {
namespace {

using IconImages = ChromeGlyphImages<ResidentFonts>;

Color ink(const QColor &color) noexcept {
  return {.r = color.redF(), .g = color.greenF(), .b = color.blueF(), .a = color.alphaF()};
}

struct IconProjection {
  fonts::IconPlacement fit;
  QPointF anchor;
  qreal scale = 1;

  [[nodiscard]] QRectF map(Rect glyph) const noexcept {
    const auto bounds = fit.map(glyph);

    return {(bounds.x - anchor.x()) / scale, (bounds.y - anchor.y()) / scale, bounds.width / scale, bounds.height / scale};
  }
};

IconProjection projection(const ChromeIconPaint &paint) {
  const Rect bounds{.x = static_cast<float>(paint.scene_origin.x() * paint.scale), .y = static_cast<float>(paint.scene_origin.y() * paint.scale), .width = static_cast<float>(paint.bounds.width() * paint.scale), .height = static_cast<float>(paint.bounds.height() * paint.scale)};

  return {.fit = fonts::IconPlacement::resolve(paint.ink, bounds, paint.target_side), .anchor = {std::floor(bounds.x), std::floor(bounds.y)}, .scale = paint.scale};
}

struct IconQuad {
  fonts::IconGlyph glyph;
  AlphaMaskRef mask;
};

class IconMesh final : public QSGGeometryNode {
public:
  IconMesh(QList<IconQuad> glyphs, Color foreground)
      : glyphs_(std::move(glyphs)),
        geometry_(alphaMaskAttributes(), static_cast<int>(static_cast<std::size_t>(glyphs_.size()) * alpha_mask_triangle_vertices)),
        // Icons are rasterized oversampled and may be rotated or scaled, so they filter.
        material_(*glyphs_.front().mask->texture, foreground, AlphaMaskSampling::filtered) {
    geometry_.setDrawingMode(QSGGeometry::DrawTriangles);
    setGeometry(&geometry_);
    setMaterial(&material_);
  }

  void paint(const IconProjection &position, Color foreground) {
    auto *vertices = static_cast<AlphaMaskVertex *>(geometry_.vertexData());
    std::size_t offset = 0;
    for (const auto &quad : glyphs_) {
      const auto source = quad.mask->texture->normalizedTextureSubRect();
      writeAlphaMaskQuad(std::span<AlphaMaskVertex, alpha_mask_triangle_vertices>{vertices + offset, alpha_mask_triangle_vertices}, position.map(quad.glyph.ink), source, 1);
      offset += alpha_mask_triangle_vertices;
    }

    material_.setForeground(foreground);
    markDirty(DirtyGeometry | DirtyMaterial);
  }

private:
  QList<IconQuad> glyphs_;
  QSGGeometry geometry_;
  AlphaMaskMaterial material_;
};

class SoftwareIcon final : public QSGNode {
public:
  SoftwareIcon(QQuickWindow &window, fonts::IconGlyph glyph)
      : glyph_(glyph),
        image_(adoptSceneNode(*this, createSceneImage(window))) {
    image_.setFiltering(QSGTexture::Nearest);
  }

  ~SoftwareIcon() override {
    clearSceneChildren(*this);
  }

  SoftwareIcon(const SoftwareIcon &) = delete;
  SoftwareIcon &operator=(const SoftwareIcon &) = delete;
  SoftwareIcon(SoftwareIcon &&) = delete;
  SoftwareIcon &operator=(SoftwareIcon &&) = delete;

  void paint(IconImages &images, const ChromeIconPaint &paint, const IconProjection &position) {
    auto colored = images.colored(glyph_.index, paint.pixel_height, glyph_.face, {}, paint.color);
    image_.setTexture(colored->texture.get());
    mask_ = std::move(colored);
    image_.setSourceRect({0, 0, static_cast<qreal>(mask_->alpha.width()), static_cast<qreal>(mask_->alpha.height())});
    image_.setRect(position.map(glyph_.ink));
  }

private:
  fonts::IconGlyph glyph_;
  tbc::view<QSGImageNode &, tbc::lt::self> image_;
  AlphaMaskRef mask_;
};

class IconScene final : public QSGTransformNode {
public:
  IconScene(QQuickWindow &window, const std::shared_ptr<const FontAsset> &source)
      : window_(window),
        source_(source),
        images_(IconImages::shared(window, ResidentFonts::shared(source))) {}

  [[nodiscard]] const FontAsset *source() const noexcept {
    return source_.get();
  }

  void paint(const ChromeIconPaint &paint) {
    if (revision_ != paint.revision) {
      rebuild(paint);
      revision_ = paint.revision;
    }

    const auto position = projection(paint);
    QMatrix4x4 transform;
    transform.translate(static_cast<float>((position.anchor.x() / paint.scale) - paint.scene_origin.x()), static_cast<float>((position.anchor.y() / paint.scale) - paint.scene_origin.y()));
    setMatrix(transform);
    for (auto *mesh : meshes_) {
      mesh->paint(position, ink(paint.color));
    }

    for (auto *glyph : software_glyphs_) {
      glyph->paint(*images_, paint, position);
    }
  }

private:
  void appendMesh(QList<IconQuad> group, const ChromeIconPaint &paint) {
    auto mesh = std::make_unique<IconMesh>(std::move(group), ink(paint.color));
    meshes_.append(&adoptSceneNode(*this, std::move(mesh)));
  }

  void rebuild(const ChromeIconPaint &paint) {
    clearSceneChildren(*this);
    meshes_.clear();
    software_glyphs_.clear();
    QList<IconQuad> group;
    for (const auto &glyph : paint.glyphs) {
      const auto &image = images_->glyph(glyph.index, paint.pixel_height, glyph.face);
      if (images_->software()) {
        auto node = std::make_unique<SoftwareIcon>(window_, glyph);
        node->paint(*images_, paint, projection(paint));
        software_glyphs_.append(&adoptSceneNode(*this, std::move(node)));
      } else {
        if (!group.empty() && group.front().mask->texture->comparisonKey() != image.mask->texture->comparisonKey()) {
          appendMesh(std::move(group), paint);
          group = {};
        }

        group.append({.glyph = glyph, .mask = image.mask});
      }
    }

    if (!group.empty()) {
      appendMesh(std::move(group), paint);
    }
  }

  QQuickWindow &window_;
  std::shared_ptr<const FontAsset> source_;
  std::shared_ptr<IconImages> images_;
  // The meshes and software glyphs are this node's children.
  tbc::view<QList<IconMesh *>, tbc::lt::self> meshes_;
  tbc::view<QList<SoftwareIcon *>, tbc::lt::self> software_glyphs_;
  std::uint64_t revision_ = 0;
};

}

QSGNode *paintChromeIcon(QSGNode *previous, QQuickWindow &window, const ChromeIconPaint &paint) {
  std::unique_ptr<IconScene> scene{dynamic_cast<IconScene *>(previous)};
  if (!scene || scene->source() != paint.source.get()) {
    scene = std::make_unique<IconScene>(window, paint.source);
  }

  scene->paint(paint);

  return scene.release();
}

}
