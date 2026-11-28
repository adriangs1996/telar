module telar.gui.ui.kit.scene;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    QRectF curveBounds(const CurvePaint& paint) noexcept {
      return {static_cast<qreal>(paint.cell.x) / paint.scale, static_cast<qreal>(paint.cell.y) / paint.scale, static_cast<qreal>(paint.cell.width) / paint.scale, static_cast<qreal>(paint.cell.height) / paint.scale};
    }

  }

  CurveScene::CurveScene(QQuickWindow& window) noexcept
      : window_(window) {}

  CurveScene::~CurveScene() = default;

  ds::Option<CurveMaskRef> CurveScene::createMask(glyphs::BoxCurve::Shape shape, Rect cell, float thickness) {
    if (cell.width > Cache::raster_limit || cell.height > Cache::raster_limit || cell.empty()) {
      return ds::none;
    }

    QImage alpha{static_cast<int>(std::ceil(cell.width)), static_cast<int>(std::ceil(cell.height)), QImage::Format_Alpha8};
    if (alpha.isNull()) {
      return ds::none;
    }

    glyphs::BoxCurve{shape, cell, thickness}.rasterize({.pixels = imageBytes(alpha), .stride = static_cast<std::size_t>(alpha.bytesPerLine()), .width = static_cast<std::uint16_t>(alpha.width()), .height = static_cast<std::uint16_t>(alpha.height())});
    std::unique_ptr<QSGTexture> texture;

    if (window_.rendererInterface()->graphicsApi() != QSGRendererInterface::Software) {
      texture.reset(window_.createTextureFromImage(alpha.convertToFormat(QImage::Format_RGBA8888_Premultiplied)));
      if (!texture) {
        return ds::none;
      }

      texture->setFiltering(QSGTexture::Linear);
    }

    auto data = std::make_unique<CurveMask>(std::move(alpha), std::move(texture));

    return CurveMaskRef{data.release()};
  }

  CurveMaskRef CurveScene::mask(const CurvePaint& paint) {
    const auto index = static_cast<std::size_t>(paint.shape);
    if (index >= glyphs::BoxCurve::shape_count) {
      throw std::invalid_argument{"InvalidBoxCurve"};
    }

    const auto metrics = glyphs::BoxMetrics::resolve(paint.cell, paint.thickness);
    const auto* cached = masks_.resolve(metrics, paint.shape, [&] {
      return createMask(paint.shape, paint.cell, paint.thickness);
    });
    if (cached != nullptr) {
      return *cached;
    }

    // Made before it is stored: making a mask borrows this scene, its fallbacks included.
    if (!fallback_[index]) {
      const auto made = createMask(paint.shape, {.width = Cache::fallback_width, .height = Cache::fallback_height}, 1).valueOr(CurveMaskRef{});

      fallback_.atMut(index) = made;
    }

    return *fallback_[index];
  }

  void CurveScene::paint(QSGNode& parent, const CurvePaint& paint) {
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

  void CurveScene::software(QSGNode& parent, const CurveMaskRef& mask, const CurvePaint& paint) const {
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
    fallback_.fill(ds::none);
  }

}
