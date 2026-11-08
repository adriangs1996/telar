#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "modal_reveal_layout.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include "window_animation_clock.hpp"
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>



import telar.gui.presentation.suggestion_labels;

namespace telar::gui::qt {

ModalRevealLayout::ModalRevealLayout(QQuickItem *parent)
    : QQuickItem(parent) {
  bindClock();
}

ModalRevealLayout::~ModalRevealLayout() {
  QObject::disconnect(frame_connection_);
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }
}

QString ModalRevealLayout::generation() const {
  return generation_;
}

bool ModalRevealLayout::active() const noexcept {
  return active_;
}

qreal ModalRevealLayout::reveal() const noexcept {
  return reveal_;
}

void ModalRevealLayout::setGeneration(const QString &generation) {
  if (generation_ == generation) {
    return;
  }

  generation_ = generation;
  bool valid = false;
  const auto identity = generation.toULongLong(&valid);
  identity_ = valid ? std::optional<std::uint64_t>{identity} : std::nullopt;
  dirty_ = true;
  synchronize();
  emit generationChanged();
}

void ModalRevealLayout::setActive(bool active) {
  if (active_ == active) {
    return;
  }

  active_ = active;
  dirty_ = true;
  synchronize();
  emit activeChanged();
}

bool ModalRevealLayout::eligible() const noexcept {
  return isVisible();
}

std::optional<std::uint64_t> ModalRevealLayout::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
  return frame_requested_ ? std::nullopt : next_sample_ns_;
}

// Prepare the zero-reveal sample before polish so geometry and targets share
// the same entrance position on the first frame.
void ModalRevealLayout::sample(std::uint64_t now_ns) {
  if (!frame_requested_ && (dirty_ || (next_sample_ns_ && now_ns >= *next_sample_ns_))) {
    frame_requested_ = true;
    if (auto *view = window()) {
      view->update();
    }
  }
}

void ModalRevealLayout::prepareFrame() {
  if (clock_.isNull() || !eligible() || (!dirty_ && !frame_requested_ && !next_sample_ns_)) {
    return;
  }

  const auto timestamp = clock_->now();
  const auto reveal = motion_.sample(active_ ? identity_ : std::nullopt, timestamp);
  const bool changed = reveal_ != reveal;
  reveal_ = reveal;
  next_sample_ns_ = motion_.deadline(timestamp, clock_->frameInterval());
  dirty_ = false;
  frame_requested_ = false;
  clock_->requestSynchronization();
  if (changed) {
    emit frameChanged();
  }
}

void ModalRevealLayout::synchronize() {
  if (!clock_.isNull()) {
    clock_->requestSynchronization();
  }
}

void ModalRevealLayout::bindClock() {
  QObject::disconnect(frame_connection_);
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (!clock_.isNull()) {
    clock_->attach(*this);
    frame_connection_ = connect(window(), &QQuickWindow::afterAnimating, this, &ModalRevealLayout::prepareFrame);
  }

  dirty_ = true;
  synchronize();
}

void ModalRevealLayout::itemChange(ItemChange change, const ItemChangeData &data) {
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
