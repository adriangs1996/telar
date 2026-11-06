#include "native_pane_attention.hpp"
#include "core/color.hpp"
#include "core/geometry.hpp"
#include "graphics/rounded_rectangle.hpp"
#include "pane_attention_value.hpp"
#include "presentation/pane_attention_geometry.hpp"
#include "presentation/pane_decoration_geometry.hpp"
#include "rounded_paints_scene.hpp"
#include "window_animation_clock.hpp"
#include <QColor>
#include <QMetaObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QVariant>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>

namespace telar::gui::qt {

NativePaneAttention::NativePaneAttention(QQuickItem *parent)
    : QQuickItem(parent),
      ancestors_(*this) {
  setFlag(ItemHasContents);
  bindClock();
}

NativePaneAttention::~NativePaneAttention() {
  if (clock_) {
    clock_->detach(*this);
  }
}

QVariant NativePaneAttention::attachment() const {
  return key_ ? paneAttentionValue(*key_) : QVariant{};
}

void NativePaneAttention::setAttachment(const QVariant &attachment) {
  const auto key = paneAttentionKey(attachment);
  if (key_ != key) {
    key_ = key;
    setAlpha(0);
    synchronize();
    emit attachmentChanged();
  }
}

bool NativePaneAttention::active() const noexcept {
  return active_;
}

void NativePaneAttention::setActive(bool active) {
  if (active_ != active) {
    active_ = active;
    if (!active) {
      setAlpha(0);
      deadline_ns_.reset();
    }

    synchronize();
    emit activeChanged();
  }
}

QColor NativePaneAttention::color() const {
  return color_;
}

void NativePaneAttention::setColor(const QColor &color) {
  if (color.isValid() && color_ != color) {
    color_ = color;
    update();
    emit colorChanged();
  }
}

qreal NativePaneAttention::ratio() const noexcept {
  return ratio_;
}

void NativePaneAttention::setRatio(qreal ratio) {
  constexpr auto maximum = std::numeric_limits<float>::max() / PaneDecorationGeometry::frame_radius;
  if (std::isfinite(ratio) && ratio > 0 && ratio <= maximum && ratio_ != ratio) {
    ratio_ = ratio;
    update();
    emit ratioChanged();
  }
}

qreal NativePaneAttention::radius() const noexcept {
  return radius_;
}

void NativePaneAttention::setRadius(qreal radius) {
  if (std::isfinite(radius) && radius >= 0 && radius <= std::numeric_limits<float>::max() && radius_ != radius) {
    radius_ = radius;
    update();
    emit radiusChanged();
  }
}

qreal NativePaneAttention::alpha() const noexcept {
  return alpha_;
}

void NativePaneAttention::setAlpha(float alpha) {
  if (alpha_ == alpha) {
    return;
  }

  alpha_ = alpha;
  update();
  if (!notification_pending_) {
    notification_pending_ = true;
    QMetaObject::invokeMethod(this, [this] {
      notification_pending_ = false;
      emit alphaChanged();
    },
                              Qt::QueuedConnection);
  }
}

bool NativePaneAttention::eligible() const noexcept {
  return active_ && key_ && key_->pane_id != 0 && key_->attachment_generation != 0 && isVisible() && width() > 0 && height() > 0;
}

std::optional<std::uint64_t> NativePaneAttention::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
  return deadline_ns_;
}

void NativePaneAttention::sample(std::uint64_t now_ns) {
  if (!clock_ || !key_ || !eligible()) {
    return;
  }

  const auto frame = clock_->sampleAttention(*key_, now_ns);
  deadline_ns_ = frame.deadline_ns;
  setAlpha(frame.alpha);
}

void NativePaneAttention::synchronize() {
  if (!eligible()) {
    setAlpha(0);
    deadline_ns_.reset();
  }

  if (clock_) {
    clock_->requestSynchronization();
  }

  update();
}

void NativePaneAttention::bindClock() {
  if (clock_) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  setAlpha(0);
  deadline_ns_.reset();
  if (clock_) {
    clock_->attach(*this);
  }

  synchronize();
}

QSGNode *NativePaneAttention::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  if (window() == nullptr || !eligible() || alpha_ <= 0) {
    const std::unique_ptr<QSGNode> retired{previous};

    return nullptr;
  }

  const auto physical_ratio = static_cast<float>(ratio_ * window()->effectiveDevicePixelRatio());
  const auto physical_width = static_cast<float>(width() * window()->effectiveDevicePixelRatio());
  const auto physical_height = static_cast<float>(height() * window()->effectiveDevicePixelRatio());
  const auto physical_radius = radius_ * physical_ratio;
  if (!std::isfinite(physical_width) || !std::isfinite(physical_height) || !std::isfinite(physical_ratio) || !std::isfinite(physical_radius) || physical_radius > std::numeric_limits<float>::max()) {
    const std::unique_ptr<QSGNode> retired{previous};

    return nullptr;
  }

  const Color color{.r = color_.redF(), .g = color_.greenF(), .b = color_.blueF(), .a = color_.alphaF() * alpha_};

  return paintRoundedShapes<1>(*this, previous, [&](auto append, Rect area) {
    const auto ring = PaneAttentionGeometry::derive(area, physical_ratio, static_cast<float>(radius_));
    if (!ring.bounds.empty()) {
      append(RoundedRectanglePaint{.origin = {.x = ring.bounds.x, .y = ring.bounds.y}, .shape = RoundedRectangle::resolve({.x = ring.bounds.width, .y = ring.bounds.height}, {.border = color, .radius = ring.radius, .border_width = ring.width})});
    }
  });
}

void NativePaneAttention::geometryChange(const QRectF &current, const QRectF &previous) {
  const QPointer<NativePaneAttention> alive{this};
  QQuickItem::geometryChange(current, previous);
  if (alive) {
    synchronize();
  }
}

void NativePaneAttention::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
  }

  if (change == ItemSceneChange) {
    bindClock();
  } else if (change == ItemVisibleHasChanged) {
    synchronize();
  }

  if (change == ItemDevicePixelRatioHasChanged || change == ItemParentHasChanged) {
    update();
  }
}

}
