#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "history_selection_layout.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include "window_animation_clock.hpp"
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>



import telar.gui.presentation.display_metrics;

namespace telar::gui::qt {

HistorySelectionLayout::HistorySelectionLayout(QQuickItem *parent)
    : QQuickItem(parent) {
  bindClock();
}

HistorySelectionLayout::~HistorySelectionLayout() {
  QObject::disconnect(frame_connection_);
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }
}

QVariantMap HistorySelectionLayout::selection() const { return selection_; }
qreal HistorySelectionLayout::selectedOpen() const noexcept { return expansion_.open; }
int HistorySelectionLayout::leavingIndex() const noexcept { return expansion_.leaving ? static_cast<int>(expansion_.leaving->index) : -1; }
QString HistorySelectionLayout::leavingKey() const { return leaving_key_; }
qreal HistorySelectionLayout::leavingOpen() const noexcept { return expansion_.leaving_open; }

void HistorySelectionLayout::setSelection(const QVariantMap &selection) {
  if (selection_ == selection) {
    return;
  }

  selection_ = selection;
  generation_.reset();
  selected_.reset();
  bool generation_valid = false;
  bool id_valid = false;
  const auto generation = selection.value(QStringLiteral("generation")).toString().toULongLong(&generation_valid);
  const auto id = selection.value(QStringLiteral("id")).toString().toULongLong(&id_valid);
  const auto index = selection.value(QStringLiteral("index"), -1).toInt();
  if (selection.value(QStringLiteral("active")).toBool() && generation_valid && id_valid && index >= 0) {
    generation_ = generation;
    selected_ = HistoryPosition{.index = static_cast<std::size_t>(index), .id = id};
  }

  dirty_ = true;
  synchronize();
  emit selectionChanged();
}

bool HistorySelectionLayout::eligible() const noexcept {
  return isVisible();
}

std::optional<std::uint64_t> HistorySelectionLayout::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
  return frame_requested_ ? std::nullopt : next_sample_ns_;
}

// Queue a frame without advancing the transition: its initial zero-open sample
// must reach layout and target registration before a later frame expands it.
void HistorySelectionLayout::sample(std::uint64_t now_ns) {
  if (!frame_requested_ && (dirty_ || (next_sample_ns_ && now_ns >= *next_sample_ns_))) {
    frame_requested_ = true;
    if (auto *view = window()) {
      view->update();
    }
  }
}

void HistorySelectionLayout::prepareFrame() {
  if (clock_.isNull() || !eligible() || (!dirty_ && !frame_requested_ && !next_sample_ns_)) {
    return;
  }

  const auto timestamp = clock_->now();
  const auto expansion = motion_.sample(generation_, selected_, timestamp);
  const bool changed = expansion_.open != expansion.open || expansion_.leaving != expansion.leaving || expansion_.leaving_open != expansion.leaving_open;
  expansion_ = expansion;
  leaving_key_ = expansion.leaving ? QString::number(expansion.leaving->id) : QString{};
  next_sample_ns_ = motion_.deadline(timestamp, clock_->frameInterval());
  dirty_ = false;
  frame_requested_ = false;
  clock_->requestSynchronization();
  if (changed) {
    emit frameChanged();
  }
}

void HistorySelectionLayout::synchronize() {
  if (!clock_.isNull()) {
    clock_->requestSynchronization();
  }
}

void HistorySelectionLayout::bindClock() {
  QObject::disconnect(frame_connection_);
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (!clock_.isNull()) {
    clock_->attach(*this);
    frame_connection_ = connect(window(), &QQuickWindow::afterAnimating, this, &HistorySelectionLayout::prepareFrame);
  }

  dirty_ = true;
  synchronize();
}

void HistorySelectionLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemSceneChange) {
    bindClock();
  } else if (change == ItemVisibleHasChanged) {
    if (!isVisible()) {
      motion_ = {};
      next_sample_ns_.reset();
      frame_requested_ = false;
    }

    dirty_ = true;
    synchronize();
  }
}

}
