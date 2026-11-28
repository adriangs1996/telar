module telar.gui.ui.app.panes;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.scene;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  PaneMotionLayout::PaneMotionLayout(QQuickItem* parent)
      : QQuickItem(parent) {
    enabled_ = qEnvironmentVariable("TELAR_GUI_PANE_ANIMATIONS") != u"0"_s;
    bindClock();
  }

  PaneMotionLayout::~PaneMotionLayout() {
    QObject::disconnect(frame_connection_);
    if (clock_) {
      clock_->detach(*this);
    }
  }

  void PaneMotionLayout::setModel(QAbstractItemModel* model) {
    if (model_ == model) {
      return;
    }

    for (const auto& connection : connections_) {
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
    modelChanged();
  }

  void PaneMotionLayout::setMotionEnabled(bool enabled) {
    if (enabled_ == enabled) {
      return;
    }

    enabled_ = enabled;
    immediate_ = true;
    polish();
    motionEnabledChanged();
  }

  bool PaneMotionLayout::eligible() const noexcept {
    return isVisible() && width() > 0 && height() > 0;
  }

  ds::Option<std::uint64_t> PaneMotionLayout::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
    return frame_requested_ ? ds::none : next_sample_ns_;
  }

  void PaneMotionLayout::sample(std::uint64_t now_ns) {
    if (!frame_requested_ && next_sample_ns_ && now_ns >= *next_sample_ns_) {
      frame_requested_ = true;
      polish();
      if (window() != nullptr) {
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
    ds::Array<application::workbench::PaneMotionSlot, PaneLayout::maximum_panes> placements;
    const auto count = model_ ? std::clamp(model_->rowCount(), 0, static_cast<int>(placements.size())) : 0;

    records.reserve(count);
    for (int index = 0; index < count; ++index) {
      auto record = model_->data(model_->index(index, 0), ListModel::record_role).toMap();

      placements.atMut(static_cast<std::size_t>(index)) = {
          .id = record.value(u"key"_s).toString().toULongLong(),
          .bounds = {.x = record.value(u"x"_s).toFloat(), .y = record.value(u"y"_s).toFloat(), .width = record.value(u"width"_s).toFloat(), .height = record.value(u"height"_s).toFloat()},
      };

      records.append(std::move(record));
    }

    const auto context = records.isEmpty() ? QString{} : records.front().value(u"motionContext"_s).toString();
    const auto now = clock_ ? clock_->now() : 0;

    motions_.update(std::span{placements}.first(static_cast<std::size_t>(count)), now, immediate_ || !enabled_ || !eligible() || context != context_);
    context_ = context;
    immediate_ = false;
    application::workbench::TabMotionFrame frame{.now_ns = now, .interval_ns = clock_ ? clock_->frameInterval() : application::workbench::TabMotionFrame::default_interval_ns, .deadline_ns = ds::none};

    for (int index = 0; index < count; ++index) {
      const auto bounds = motions_.place(static_cast<std::size_t>(index), frame);
      const auto& record = records[index];
      const auto visual = bounds == placements[static_cast<std::size_t>(index)].bounds
                              ? QRectF{record.value(u"x"_s).toReal(), record.value(u"y"_s).toReal(), record.value(u"width"_s).toReal(), record.value(u"height"_s).toReal()}
                              : QRectF{static_cast<qreal>(bounds.x), static_cast<qreal>(bounds.y), static_cast<qreal>(bounds.width), static_cast<qreal>(bounds.height)};

      records[index].insert(u"visualBounds"_s, visual);
    }

    next_sample_ns_ = frame.deadline_ns;
    frame_requested_ = false;
    if (clock_) {
      clock_->requestSynchronization();
    }

    items_.reconcile(std::move(records));
  }

  void PaneMotionLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    if (current.size() != previous.size()) {
      immediate_ = true;
      polish();
    }
  }

  void PaneMotionLayout::itemChange(ItemChange change, const ItemChangeData& data) {
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
