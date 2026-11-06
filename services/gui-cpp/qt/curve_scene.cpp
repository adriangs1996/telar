#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "curve_scene.hpp"
#include "curve_mask.hpp"
#include "curve_mask_node.hpp"
#include "projection.hpp"
#include "scene_nodes.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <algorithm>
#include <cmath>
#include <array>
#include <limits>
#include <optional>
#include <QImage>
#include <QPainter>
#include <QRectF>
#include <QSGNode>
#include <QSGRendererInterface>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QtCore/qtypes.h>
#include <memory>
#include <utility>



import telar.gui.terminal.glyphs.curve_cache;

namespace telar::gui::qt {

namespace {

QRectF curveBounds(const CurvePaint &paint) noexcept {
  return {paint.cell.x / paint.scale, paint.cell.y / paint.scale, paint.cell.width / paint.scale, paint.cell.height / paint.scale};
}

}

CurveScene::CurveScene(QQuickWindow &window) noexcept
    : window_(window) {}

std::optional<CurveMaskRef> CurveScene::createMask(glyphs::BoxCurve::Shape shape, Rect cell, float thickness) {
  if (cell.width > Cache::raster_limit || cell.height > Cache::raster_limit || cell.empty()) {
    return std::nullopt;
  }

  QImage alpha{static_cast<int>(std::ceil(cell.width)), static_cast<int>(std::ceil(cell.height)), QImage::Format_Alpha8};
  if (alpha.isNull()) {
    return std::nullopt;
  }

  glyphs::BoxCurve{shape, cell, thickness}.rasterize({.pixels = std::span{alpha.bits(), static_cast<std::size_t>(alpha.sizeInBytes())}, .stride = static_cast<std::size_t>(alpha.bytesPerLine()), .width = static_cast<std::uint16_t>(alpha.width()), .height = static_cast<std::uint16_t>(alpha.height())});
  std::unique_ptr<QSGTexture> texture;
  if (window_.rendererInterface()->graphicsApi() != QSGRendererInterface::Software) {
    texture.reset(window_.createTextureFromImage(alpha.convertToFormat(QImage::Format_RGBA8888_Premultiplied)));
    if (!texture) {
      return std::nullopt;
    }

    texture->setFiltering(QSGTexture::Linear);
  }

  auto data = std::make_unique<CurveMask>(std::move(alpha), std::move(texture));

  return CurveMaskRef{data.release()};
}

CurveMaskRef CurveScene::mask(const CurvePaint &paint) {
  const auto index = static_cast<std::size_t>(paint.shape);
  if (index >= glyphs::BoxCurve::shape_count) {
    throw std::invalid_argument{"InvalidBoxCurve"};
  }

  const auto metrics = glyphs::BoxMetrics::resolve(paint.cell, paint.thickness);
  const auto *cached = masks_.resolve(metrics, paint.shape, [&] {
    return createMask(paint.shape, paint.cell, paint.thickness);
  });
  if (cached != nullptr) {
    return *cached;
  }

  auto &reserved = fallback_[index];
  if (!reserved) {
    reserved = createMask(paint.shape, {.width = Cache::fallback_width, .height = Cache::fallback_height}, 1).value_or(CurveMaskRef{});
  }

  return *reserved;
}

void CurveScene::paint(QSGNode &parent, const CurvePaint &paint) {
  if (!std::isfinite(paint.scale) || paint.scale <= 0) {
    throw std::invalid_argument{"InvalidGlyphScale"};
  }

  if (paint.cell.empty()) {
    return;
  }

  const auto image = mask(paint);
  if (!image) {
    return;
  }

  if (window_.rendererInterface()->graphicsApi() == QSGRendererInterface::Software) {
    software(parent, image, paint);
  } else {
    appendCurveMask(parent, image, curveBounds(paint), paint.foreground);
  }
}

void CurveScene::software(QSGNode &parent, const CurveMaskRef &mask, const CurvePaint &paint) const {
  auto pixels = mask->alpha.convertToFormat(QImage::Format_ARGB32_Premultiplied);
  QPainter painter{&pixels};
  painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
  painter.fillRect(pixels.rect(), toQColor(paint.foreground));
  painter.end();
  std::unique_ptr<QSGTexture> texture{window_.createTextureFromImage(pixels)};
  if (!texture) {
    return;
  }

  auto node = std::make_unique<QSGSimpleTextureNode>();
  node->setOwnsTexture(true);
  node->setTexture(texture.release());
  node->setFiltering(QSGTexture::Linear);
  node->setRect(curveBounds(paint));
  adoptSceneNode(parent, std::move(node));
}

void CurveScene::reset() noexcept {
  masks_.reset();
  std::ranges::fill(fallback_, std::nullopt);
}

}
