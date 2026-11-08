#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "history_loading_layout.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <concepts>
#include <limits>
#include <numbers>
#include "projection.hpp"
#include "window_animation_clock.hpp"
#include <QQuickWindow>
#include <QQuickItem>
#include <QPointer>
#include <QRectF>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>



import telar.gui.core.metrics;
import telar.gui.platform.profile_file;
import telar.gui.presentation.display_metrics;

namespace telar::gui::qt {

HistoryLoadingLayout::HistoryLoadingLayout(QQuickItem *parent)
    : QQuickItem(parent) {
  bindClock();
}

HistoryLoadingLayout::~HistoryLoadingLayout() {
  if (clock_) {
    clock_->detach(*this);
  }
}

bool HistoryLoadingLayout::waiting() const noexcept {
  return waiting_;
}

qreal HistoryLoadingLayout::ratio() const noexcept {
  return ratio_;
}

bool HistoryLoadingLayout::cueVisible() const noexcept {
  return cue_visible_;
}

qreal HistoryLoadingLayout::rowsOpacity() const noexcept {
  return cue_visible_ ? HistoryLoading::row_opacity : 1;
}

QRectF HistoryLoadingLayout::line() const noexcept {
  return line_;
}


void HistoryLoadingLayout::setWaiting(bool waiting) {
  if (waiting_ != waiting) {
    waiting_ = waiting;
    const QPointer<HistoryLoadingLayout> alive{this};
    emit waitingChanged();
    if (alive) {
      synchronize();
    }
  }
}

void HistoryLoadingLayout::setRatio(qreal ratio) {
  if (std::isfinite(ratio) && ratio > 0 && ratio_ != ratio) {
    ratio_ = ratio;
    const QPointer<HistoryLoadingLayout> alive{this};
    emit ratioChanged();
    if (alive) {
      synchronize();
    }
  }
}

bool HistoryLoadingLayout::eligible() const noexcept {
  return waiting_ && isVisible() && width() > 0 && height() > 0;
}

std::optional<std::uint64_t> HistoryLoadingLayout::deadline(std::uint64_t now_ns) const noexcept {
  return cue_visible_ ? std::optional{ProgressAnimation::nextStep(now_ns, HistoryLoading::step_ns)} : cue_.deadline();
}

void HistoryLoadingLayout::sample(std::uint64_t now_ns) {
  if (waiting_ && !eligible()) {
    return;
  }

  const auto visible = cue_.sample(waiting_, now_ns);
  const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  ChromeMetrics chrome;
  chrome.ratio = static_cast<float>(ratio_ * density);
  const Rect area{.width = static_cast<float>(width() * density), .height = static_cast<float>(height() * density)};
  const auto line = visible ? toQRectF(HistoryLoading::line(area, chrome, now_ns), density) : QRectF{};
  if (cue_visible_ != visible || line_ != line) {
    cue_visible_ = visible;
    line_ = line;
    emit frameChanged();
  }
}

void HistoryLoadingLayout::synchronize() {
  if (clock_) {
    clock_->requestSynchronization();
  }

  sample(clock_ ? clock_->now() : platform::AwakeClock::nowNanoseconds());
}

void HistoryLoadingLayout::bindClock() {
  if (clock_) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (clock_) {
    clock_->attach(*this);
  }

  synchronize();
}

void HistoryLoadingLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemSceneChange) {
    bindClock();
  } else if (change == ItemVisibleHasChanged || change == ItemDevicePixelRatioHasChanged) {
    synchronize();
  }
}

void HistoryLoadingLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  synchronize();
}

}
