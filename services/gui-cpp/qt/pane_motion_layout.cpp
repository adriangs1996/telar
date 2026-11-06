#include "pane_motion_layout.hpp"
#include "window_animation_clock.hpp"
#include <QQuickWindow>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qtenvironmentvariables.h>
#include <algorithm>
#include <array>
#include <cstddef>

namespace telar::gui::qt {

PaneMotionLayout::PaneMotionLayout(QQuickItem *parent)
    : QQuickItem(parent) {
  enabled_ = qEnvironmentVariable("TELAR_GUI_PANE_ANIMATIONS") != QStringLiteral("0");
  bindClock();
}

PaneMotionLayout::~PaneMotionLayout() {
  QObject::disconnect(frame_connection_);
  if (clock_) {
    clock_->detach(*this);
  }
}

void PaneMotionLayout::setModel(QAbstractItemModel *model) {
  if (model_ == model) {
    return;
  }
  for (const auto &connection : connections_) {
    QObject::disconnect(connection);
  }
  model_ = model;
  immediate_ = true;
  if (model != nullptr) {
    const auto changed = [this] {
      polish();
    };
    connections_ = {
        connect(model, &QAbstractItemModel::dataChanged, this, changed),
        connect(model, &QAbstractItemModel::rowsInserted, this, changed),
        connect(model, &QAbstractItemModel::rowsRemoved, this, changed),
        connect(model, &QAbstractItemModel::rowsMoved, this, changed),
        connect(model, &QAbstractItemModel::modelReset, this, [this] {
          immediate_ = true;
          polish();
        }),
        connect(model, &QObject::destroyed, this, [this] {
          immediate_ = true;
          polish();
        }),
    };
  }
  polish();
  emit modelChanged();
}

void PaneMotionLayout::setMotionEnabled(bool enabled) {
  if (enabled_ == enabled) {
    return;
  }
  enabled_ = enabled;
  immediate_ = true;
  polish();
  emit motionEnabledChanged();
}

bool PaneMotionLayout::eligible() const noexcept {
  return isVisible() && width() > 0 && height() > 0;
}

std::optional<std::uint64_t> PaneMotionLayout::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
  return frame_requested_ ? std::nullopt : next_sample_ns_;
}

void PaneMotionLayout::sample(std::uint64_t now_ns) {
  if (!frame_requested_ && next_sample_ns_ && now_ns >= *next_sample_ns_) {
    frame_requested_ = true;
    polish();
    if (window()) {
      window()->update();
    }
  }
}

void PaneMotionLayout::bindClock() {
  QObject::disconnect(frame_connection_);
  if (clock_) {
    clock_->detach(*this);
  }
  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (clock_) {
    clock_->attach(*this);
    frame_connection_ = connect(window(), &QQuickWindow::afterAnimating, this, [this] {
      if (eligible() && next_sample_ns_) {
        frame_requested_ = true;
        polish();
      }
    });
  }
  immediate_ = true;
  polish();
}

void PaneMotionLayout::updatePolish() {
  QList<QVariantMap> records;
  std::array<PaneMotionSlot, PaneLayout::maximum_panes> placements;
  const auto count = model_ ? std::clamp(model_->rowCount(), 0, static_cast<int>(placements.size())) : 0;
  records.reserve(count);
  for (int index = 0; index < count; ++index) {
    auto record = model_->data(model_->index(index, 0), ListModel::record_role).toMap();
    placements[static_cast<std::size_t>(index)] = {
        .id = record.value(QStringLiteral("key")).toString().toULongLong(),
        .bounds = {.x = record.value(QStringLiteral("x")).toFloat(), .y = record.value(QStringLiteral("y")).toFloat(), .width = record.value(QStringLiteral("width")).toFloat(), .height = record.value(QStringLiteral("height")).toFloat()},
    };
    records.append(std::move(record));
  }
  const auto context = records.isEmpty() ? QString{} : records.front().value(QStringLiteral("motionContext")).toString();
  const auto now = clock_ ? clock_->now() : 0;
  motions_.update(std::span{placements}.first(static_cast<std::size_t>(count)), now, immediate_ || !enabled_ || !eligible() || context != context_);
  context_ = context;
  immediate_ = false;
  TabMotionFrame frame{.now_ns = now, .interval_ns = clock_ ? clock_->frameInterval() : TabMotionFrame::default_interval_ns, .deadline_ns = std::nullopt};
  for (int index = 0; index < count; ++index) {
    const auto bounds = motions_.place(static_cast<std::size_t>(index), frame);
    const auto &record = records[index];
    const auto visual = bounds == placements[static_cast<std::size_t>(index)].bounds
                            ? QRectF{record.value(QStringLiteral("x")).toReal(), record.value(QStringLiteral("y")).toReal(), record.value(QStringLiteral("width")).toReal(), record.value(QStringLiteral("height")).toReal()}
                            : QRectF{bounds.x, bounds.y, bounds.width, bounds.height};
    records[index].insert(QStringLiteral("visualBounds"), visual);
  }
  next_sample_ns_ = frame.deadline_ns;
  frame_requested_ = false;
  if (clock_) {
    clock_->requestSynchronization();
  }
  items_.reconcile(std::move(records));
}

void PaneMotionLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  if (current.size() != previous.size()) {
    immediate_ = true;
    polish();
  }
}

void PaneMotionLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemSceneChange) {
    bindClock();
  } else if (change == ItemVisibleHasChanged) {
    immediate_ = true;
    next_sample_ns_.reset();
    frame_requested_ = false;
    polish();
    if (clock_) {
      clock_->requestSynchronization();
    }
  }
}

}
