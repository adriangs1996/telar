#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "native_agent_status.hpp"
#include "agent_status_value.hpp"
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <algorithm>
#include <cmath>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <numbers>
#include "window_animation_clock.hpp"
#include <QAnyStringView>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>



import telar.gui.platform.profile_file;
import telar.gui.presentation.suggestion_labels;
import telar.gui.presentation.activity_order;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.application_mark;

namespace telar::gui::qt {

NativeAgentStatus::NativeAgentStatus(QQuickItem *parent)
    : QQuickItem(parent) {
  bindClock();
}

NativeAgentStatus::~NativeAgentStatus() {
  if (clock_) {
    clock_->detach(*this);
  }
}

QVariantMap NativeAgentStatus::record() const {
  return record_;
}

QString NativeAgentStatus::statusText() const {
  return status_text_;
}

qreal NativeAgentStatus::animatedAlpha() const noexcept {
  return animated_alpha_;
}

bool NativeAgentStatus::running() const noexcept {
  return running_;
}

NativeAgentStatus::DisplayMode NativeAgentStatus::displayMode() const noexcept {
  return display_mode_;
}

void NativeAgentStatus::setDisplayMode(DisplayMode mode) {
  if (display_mode_ != mode) {
    display_mode_ = mode;
    const QPointer<NativeAgentStatus> alive{this};
    synchronize();
    if (alive) {
      emit displayModeChanged();
    }
  }
}

void NativeAgentStatus::setRecord(const QVariantMap &record) {
  if (record_ == record) {
    return;
  }

  record_ = record;
  const auto timestamp = clock_ ? clock_->now() : platform::AwakeClock::nowNanoseconds();
  interval_ = statusAgeInterval(record.value(QStringLiteral("statusClock"))).value_or(StatusAgeInterval{.age_ns = static_cast<std::uint64_t>(record.value(QStringLiteral("age")).toUInt()) * StatusAgeInterval::nanoseconds_per_second, .sampled_ns = timestamp});
  const auto state = record.value(QStringLiteral("statusCode")).toInt();
  status_ = state >= static_cast<int>(AgentStatus::unknown) && state <= static_cast<int>(AgentStatus::done) ? static_cast<AgentStatus>(state) : AgentStatus::unknown;
  const auto reason = record.value(QStringLiteral("blockedReason")).toInt();
  reason_ = reason >= static_cast<int>(AgentBlockedReason::none) && reason <= static_cast<int>(AgentBlockedReason::other) ? static_cast<AgentBlockedReason>(reason) : AgentBlockedReason::none;
  connected_ = record.value(QStringLiteral("enabled"), true).toBool();
  const QPointer<NativeAgentStatus> alive{this};
  synchronize();
  if (alive) {
    emit recordChanged();
  }
}

void NativeAgentStatus::setRunning(bool running) {
  if (running_ != running) {
    running_ = running;
    const QPointer<NativeAgentStatus> alive{this};
    synchronize();
    if (alive) {
      emit runningChanged();
    }
  }
}

bool NativeAgentStatus::eligible() const noexcept {
  return running_ && isVisible() && width() > 0 && height() > 0;
}

std::optional<std::uint64_t> NativeAgentStatus::deadline(std::uint64_t now_ns) const noexcept {
  if (display_mode_ == DisplayMode::pane_chip) {
    if (connected_ && status_ == AgentStatus::working) {
      return ProgressAnimation::nextStep(now_ns, StatusAgeInterval::nanoseconds_per_second);
    }

    return std::nullopt;
  }

  const auto state = display_mode_ == DisplayMode::compact && status_ != AgentStatus::working ? AgentStatus::ready : status_;

  return AgentAnimation::deadline(state, connected_, now_ns);
}

void NativeAgentStatus::sample(std::uint64_t now_ns) {
  const auto seconds = interval_.seconds(now_ns);
  AgentStatusPresentation::Text text;
  if (display_mode_ == DisplayMode::pane_chip) {
    text = PaneStatusChip::text(status_, reason_, seconds);
  } else if (display_mode_ == DisplayMode::compact) {
    text.append(AgentStatusPresentation::age(seconds).view());
  } else {
    text = AgentStatusPresentation::text(status_, reason_, seconds, connected_);
  }
  const QAnyStringView label{text.view()};
  const auto alpha = display_mode_ != DisplayMode::pane_chip && connected_ && status_ == AgentStatus::working ? AgentAnimation::alpha(now_ns) : 1;
  const auto text_changed = QAnyStringView::compare(status_text_, label) != 0;
  const auto alpha_changed = animated_alpha_ != alpha;
  if (!text_changed && !alpha_changed) {
    return;
  }

  if (text_changed) {
    status_text_ = label.toString();
  }

  animated_alpha_ = alpha;
  const QPointer<NativeAgentStatus> alive{this};
  if (text_changed) {
    emit statusTextChanged();
  }

  if (alive && alpha_changed) {
    emit animatedAlphaChanged();
  }
}

void NativeAgentStatus::synchronize() {
  if (clock_) {
    clock_->requestSynchronization();
  }

  sample(clock_ ? clock_->now() : platform::AwakeClock::nowNanoseconds());
}

void NativeAgentStatus::bindClock() {
  if (clock_) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (clock_) {
    clock_->attach(*this);
  }

  synchronize();
}

void NativeAgentStatus::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemSceneChange) {
    bindClock();
  } else if (change == ItemVisibleHasChanged) {
    synchronize();
  }
}

void NativeAgentStatus::geometryChange(const QRectF &current, const QRectF &previous) {
  const QPointer<NativeAgentStatus> alive{this};
  QQuickItem::geometryChange(current, previous);
  if (alive) {
    synchronize();
  }
}

}
