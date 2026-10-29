#include "provider_mark.hpp"
#include "presentation/application_mark.hpp"
#include "provider_artwork.hpp"
#include "scene_nodes.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <QColor>
#include <QImage>
#include <QMatrix4x4>
#include <QObject>
#include <QPainter>
#include <QPointF>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QSGTransformNode>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

namespace telar::gui::qt {

namespace {

class ProviderNode final : public QSGTransformNode {
public:
  ProviderNode()
      : image(appendSceneNode<QSGSimpleTextureNode>(*this)) {}

  QSGSimpleTextureNode &image;
  std::unique_ptr<QSGTexture> texture;
  int side = 0;
};

QImage coloredMark(AgentProvider provider, int side, const QColor &color) {
  auto image = ProviderArtwork::image(provider, side);
  if (!image.isNull() && ApplicationMark{.provider = provider}.followsTheme()) {
    QPainter painter{&image};
    painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
    painter.fillRect(image.rect(), color);
  }

  return image;
}

}

ProviderMark::ProviderMark(QQuickItem *parent)
    : QQuickItem(parent),
      ancestors_(*this) {
  setFlag(ItemHasContents);
}

ProviderMark::~ProviderMark() = default;

qreal ProviderMark::dimmedAlpha() noexcept {
  return ApplicationMark::dimmed_alpha;
}

int ProviderMark::provider() const noexcept {
  return static_cast<int>(provider_);
}

QColor ProviderMark::color() const {
  return color_;
}

qreal ProviderMark::ratio() const noexcept {
  return ratio_;
}

void ProviderMark::setProvider(int provider) {
  const auto value = static_cast<AgentProvider>(provider);
  if (provider_ != value) {
    provider_ = value;
    dirty_ = true;
    emit providerChanged();
    update();
  }
}

void ProviderMark::setColor(const QColor &color) {
  if (color_ != color) {
    color_ = color;
    dirty_ = true;
    emit colorChanged();
    update();
  }
}

void ProviderMark::setRatio(qreal ratio) {
  if (std::isfinite(ratio) && ratio > 0 && ratio_ != ratio) {
    ratio_ = ratio;
    dirty_ = true;
    emit ratioChanged();
    update();
  }
}

QSGNode *ProviderMark::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  std::unique_ptr<ProviderNode> node{dynamic_cast<ProviderNode *>(previous)};
  if (window() == nullptr || width() <= 0 || height() <= 0 || provider_ == AgentProvider::unknown) {
    return nullptr;
  }

  const auto scale = window()->effectiveDevicePixelRatio();
  const auto physical_ratio = static_cast<float>(ratio_ * scale);
  const auto wanted = std::round(ApplicationMark::atlas_cell_side * physical_ratio);
  const auto side = static_cast<int>(std::clamp(wanted, static_cast<float>(ApplicationMark::minimum_cell), static_cast<float>(ApplicationMark::maximum_cell)));
  if (!node) {
    node = std::make_unique<ProviderNode>();
  }

  if (dirty_ || !node->texture || node->side != side) {
    const auto pixels = coloredMark(provider_, side, color_);
    if (pixels.isNull()) {
      return nullptr;
    }

    std::unique_ptr<QSGTexture> texture{window()->createTextureFromImage(pixels)};
    if (!texture) {
      return nullptr;
    }

    node->image.setTexture(texture.get());
    node->texture = std::move(texture);
    node->image.setFiltering(QSGTexture::Linear);
    node->side = side;
    dirty_ = false;
  }

  const auto origin = mapToScene(QPointF{});
  const QPointF offset{(std::floor(origin.x() * scale) / scale) - origin.x(), (std::floor(origin.y() * scale) / scale) - origin.y()};
  QMatrix4x4 transform;
  transform.translate(static_cast<float>(offset.x()), static_cast<float>(offset.y()));
  node->setMatrix(transform);
  node->image.setRect(QRectF{QPointF{}, size()});

  return node.release();
}

void ProviderMark::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  update();
}

void ProviderMark::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
    update();
  }

  if (change == ItemDevicePixelRatioHasChanged) {
    update();
  }
}

}
