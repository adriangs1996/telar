#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include <cmath>
#include "rounded_rectangle_scene.hpp"
#include <QColor>
#include <QMatrix4x4>
#include <QPaintDevice>
#include <QPainter>
#include <QPointF>
#include <QQuickWindow>
#include <QRect>
#include <QRectF>
#include <QRegion>
#include <QSGNode>
#include <QSGRenderNode>
#include <QSGRendererInterface>
#include <QTransform>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <memory>
#include <utility>



import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;

namespace telar::gui::qt {
namespace {

QTransform devicePixelTransform(const QTransform &matrix) {
  return {static_cast<float>(matrix.m11()), static_cast<float>(matrix.m12()), static_cast<float>(matrix.m13()), static_cast<float>(matrix.m21()), static_cast<float>(matrix.m22()), static_cast<float>(matrix.m23()), static_cast<float>(matrix.m31()), static_cast<float>(matrix.m32()), static_cast<float>(matrix.m33())};
}

QRectF rasterCoverage(const QTransform &transform, Point size, qreal density) {
  constexpr unsigned subpixel_bits = 8;
  constexpr qreal subpixel_steps = 1U << subpixel_bits;
  const auto bounds = transform.mapRect(QRectF{0, 0, size.x / density, size.y / density});
  const auto quantize = [](qreal coordinate) {
    return std::round(coordinate * subpixel_steps) / subpixel_steps;
  };

  return {QPointF{quantize(bounds.left()), quantize(bounds.top())}, QPointF{quantize(bounds.right()), quantize(bounds.bottom())}};
}

class ShapeScanlines {
public:
  ShapeScanlines(QPainter &painter, RoundedRectangle shape, qreal density, const QTransform &item_to_device, Point raster_size)
      : painter_(painter),
        shape_(shape),
        density_(density),
        item_to_device_(item_to_device),
        device_to_item_(item_to_device.inverted()),
        raster_size_(raster_size),
        raster_coverage_(rasterCoverage(item_to_device, raster_size, density)) {
    const auto padding = (shape.style.radius + shape.style.border_width + 1) / density;
    const QRectF interior{padding, 0, std::max(0.0, (shape.size.x / density) - (2 * padding)), shape.size.y / density};
    if (item_to_device.type() <= QTransform::TxScale && interior.width() > 0) {
      const auto device_interior = item_to_device.mapRect(interior);
      interior_left_ = device_interior.left();
      interior_right_ = device_interior.right();
    }
  }

  void paint(const QRect &bounds) const {
    constexpr qreal pixel_center = 0.5;
    const auto interior_begin = static_cast<int>(std::clamp(std::ceil(interior_left_ - pixel_center), static_cast<qreal>(bounds.left()), static_cast<qreal>(bounds.right() + 1)));
    const auto interior_end = static_cast<int>(std::clamp(std::ceil(interior_right_ - pixel_center), static_cast<qreal>(interior_begin), static_cast<qreal>(bounds.right() + 1)));
    for (int row = bounds.top(); row <= bounds.bottom(); ++row) {
      paintRange(row, bounds.left(), interior_begin);
      if (interior_end > interior_begin) {
        paintSpan(row, interior_begin, interior_end, sample(interior_begin, row));
      }

      paintRange(row, interior_end, bounds.right() + 1);
    }
  }

private:
  [[nodiscard]] QPointF localPoint(QPointF pixel) const {
    if (item_to_device_.type() <= QTransform::TxScale) {
      return {(pixel.x() - item_to_device_.dx()) / item_to_device_.m11(), (pixel.y() - item_to_device_.dy()) / item_to_device_.m22()};
    }

    return device_to_item_.map(pixel);
  }

  [[nodiscard]] Color sample(int column, int row) const {
    constexpr qreal pixel_center = 0.5;
    const QPointF center{column + pixel_center, row + pixel_center};
    const auto logical = localPoint(center);
    const Point local{.x = static_cast<float>(logical.x() * density_), .y = static_cast<float>(logical.y() * density_)};
    const auto outside = item_to_device_.type() <= QTransform::TxScale
                             ? center.x() < raster_coverage_.left() || center.y() < raster_coverage_.top() || center.x() >= raster_coverage_.right() || center.y() >= raster_coverage_.bottom()
                             : local.x < 0 || local.y < 0 || local.x >= raster_size_.x || local.y >= raster_size_.y;
    if (outside) {
      return {.a = 0};
    }

    return shape_.sample(local);
  }

  void paintSpan(int row, int begin, int end, Color color) const {
    if (end > begin && color.a > 0) {
      painter_.fillRect(QRect{begin, row, end - begin, 1}, QColor::fromRgbF(color.r, color.g, color.b, color.a));
    }
  }

  void paintRange(int row, int begin, int end) const {
    if (begin >= end) {
      return;
    }

    auto color = sample(begin, row);
    auto span_begin = begin;
    for (int column = begin + 1; column < end; ++column) {
      const auto next = sample(column, row);
      if (color != next) {
        paintSpan(row, span_begin, column, color);
        color = next;
        span_begin = column;
      }
    }

    paintSpan(row, span_begin, end, color);
  }

  QPainter &painter_;
  RoundedRectangle shape_;
  qreal density_;
  QTransform item_to_device_;
  QTransform device_to_item_;
  Point raster_size_;
  QRectF raster_coverage_;
  qreal interior_left_ = 0;
  qreal interior_right_ = 0;
};

class SoftwareRoundedRectangleNode final : public QSGRenderNode {
public:
  explicit SoftwareRoundedRectangleNode(QQuickWindow &window)
      : window_(window) {}

  void refresh(RoundedRectanglePaint paint, qreal density) {
    if (shape_ != paint.shape || density_ != density || origin_ != paint.origin) {
      shape_ = paint.shape;
      origin_ = paint.origin;
      density_ = density;
      markDirty(DirtyGeometry | DirtyMaterial);
    }
  }

  [[nodiscard]] QRectF rect() const override {
    constexpr qreal raster_padding = 1;
    const auto padding = raster_padding / density_;

    return {(origin_.x / density_) - padding, (origin_.y / density_) - padding, (shape_.size.x / density_) + (2 * padding), (shape_.size.y / density_) + (2 * padding)};
  }

  [[nodiscard]] RenderingFlags flags() const override {
    return BoundedRectRendering;
  }

  void render(const RenderState *state) override {
    auto *painter = static_cast<QPainter *>(window_.rendererInterface()->getResource(&window_, QSGRendererInterface::PainterResource));
    if (painter == nullptr || matrix() == nullptr) {
      return;
    }

    painter->resetTransform();
    if (state->clipRegion() != nullptr) {
      painter->setClipRegion(*state->clipRegion(), Qt::IntersectClip);
    }

    painter->setWorldTransform(matrix()->toTransform());
    painter->translate(origin_.x / density_, origin_.y / density_);
    const auto item_to_device = devicePixelTransform(painter->deviceTransform());
    if (!item_to_device.isInvertible()) {
      return;
    }

    const Point raster_size{.x = (origin_.x + shape_.size.x) - origin_.x, .y = (origin_.y + shape_.size.y) - origin_.y};
    const QRectF local_bounds{0, 0, raster_size.x / density_, raster_size.y / density_};
    const auto bounds = item_to_device.mapRect(local_bounds).toAlignedRect().intersected(QRect{0, 0, painter->device()->width(), painter->device()->height()});
    painter->resetTransform();
    painter->setWorldTransform(painter->deviceTransform().inverted());
    painter->setOpacity(inheritedOpacity());
    painter->setRenderHint(QPainter::Antialiasing, false);
    painter->setCompositionMode(QPainter::CompositionMode_SourceOver);
    ShapeScanlines{*painter, shape_, density_, item_to_device, raster_size}.paint(bounds);
  }

private:
  QQuickWindow &window_;
  RoundedRectangle shape_;
  Point origin_;
  qreal density_ = 1;
};

}

QSGNode *paintSoftwareRoundedRectangle(QQuickWindow &window, QSGNode *previous, RoundedRectangle shape, qreal density) {
  return paintSoftwareRoundedRectangleAt(window, previous, {.shape = shape}, density);
}

QSGNode *paintSoftwareRoundedRectangleAt(QQuickWindow &window, QSGNode *previous, RoundedRectanglePaint paint, qreal density) {
  auto owner = std::unique_ptr<QSGNode>{previous};
  auto *node = dynamic_cast<SoftwareRoundedRectangleNode *>(previous);
  if (node == nullptr) {
    auto replacement = std::make_unique<SoftwareRoundedRectangleNode>(window);
    node = replacement.get();
    owner = std::move(replacement);
  }

  node->refresh(paint, density);

  return owner.release();
}

}
