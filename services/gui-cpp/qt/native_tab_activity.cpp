#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "native_tab_activity.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include <cmath>
#include "telar_client/serializers/telar_protocol.hpp"
#include <numbers>
#include <concepts>
#include <limits>
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include <tuple>
#include <charconv>
#include <cstring>
#include <system_error>
#include "progress_value.hpp"
#include "rounded_paints_scene.hpp"
#include "window_animation_clock.hpp"
#include <QColor>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QString>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <memory>



import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;
import telar.gui.platform.profile_file;
import telar.gui.platform.private_file_stamp;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.activity_order;

namespace telar::gui::qt {

NativeTabActivity::NativeTabActivity(QQuickItem *parent)
    : QQuickItem(parent),
      ancestors_(*this) {
  setFlag(ItemHasContents);
  bindClock();
}

NativeTabActivity::~NativeTabActivity() {
  if (clock_) {
    clock_->detach(*this);
  }
}

QVariantMap NativeTabActivity::record() const {
  return record_;
}

QColor NativeTabActivity::color() const {
  return color_;
}

qreal NativeTabActivity::ratio() const noexcept {
  return ratio_;
}

bool NativeTabActivity::running() const noexcept {
  return running_;
}

bool NativeTabActivity::compact() const noexcept {
  return compact_;
}

void NativeTabActivity::setCompact(bool compact) {
  if (compact_ != compact) {
    compact_ = compact;
    update();
    emit compactChanged();
  }
}

qreal NativeTabActivity::fraction() const noexcept {
  return fraction_;
}

qreal NativeTabActivity::turns() const noexcept {
  return turns_;
}

void NativeTabActivity::setRecord(const QVariantMap &record) {
  if (record_ == record) {
    return;
  }

  record_ = record;
  const auto kind = record.value(QStringLiteral("activityKind")).toInt();
  kind_ = kind >= static_cast<int>(TabActivity::Kind::none) && kind <= static_cast<int>(TabActivity::Kind::progress) ? static_cast<TabActivity::Kind>(kind) : TabActivity::Kind::none;
  const auto value = record.value(QStringLiteral("progressSample"));
  progress_ = progressSample(value).value_or(ProgressSample{});
  if (kind_ != TabActivity::Kind::progress) {
    motion_ = {};
  }

  const QPointer<NativeTabActivity> alive{this};
  synchronize();
  if (alive) {
    update();
    emit recordChanged();
  }
}

void NativeTabActivity::setColor(const QColor &color) {
  if (color.isValid() && color_ != color) {
    color_ = color;
    update();
    emit colorChanged();
  }
}

void NativeTabActivity::setRatio(qreal ratio) {
  const auto maximum = std::numeric_limits<float>::max() / ProgressGeometry::compactWidth();
  if (std::isfinite(ratio) && ratio > 0 && ratio <= maximum && ratio_ != ratio) {
    ratio_ = ratio;
    update();
    emit ratioChanged();
  }
}

void NativeTabActivity::setRunning(bool running) {
  if (running_ != running) {
    running_ = running;
    const QPointer<NativeTabActivity> alive{this};
    synchronize();
    if (alive) {
      emit runningChanged();
    }
  }
}

bool NativeTabActivity::eligible() const noexcept {
  return running_ && isVisible() && width() > 0 && height() > 0;
}

std::optional<std::uint64_t> NativeTabActivity::deadline(std::uint64_t now_ns) const noexcept {
  if (kind_ == TabActivity::Kind::spinner) {
    return ProgressAnimation::nextStep(now_ns, TabActivity::spinner_interval_ns);
  }

  if (kind_ != TabActivity::Kind::progress) {
    return std::nullopt;
  }

  const auto interval = clock_ ? clock_->frameInterval() : 1;
  const auto next_frame = now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, interval);
  if (progress_.state == PaneProgressState::indeterminate) {
    return next_frame;
  }

  const auto end = motion_.deadline(now_ns);

  return end ? std::optional{std::min(next_frame, *end)} : std::nullopt;
}

void NativeTabActivity::sample(std::uint64_t now_ns) {
  if (!eligible()) {
    motion_ = {};
    return;
  }

  float fraction = 0;
  float turns = 0;
  if (kind_ == TabActivity::Kind::spinner) {
    fraction = TabActivity::spinner_fraction;
    turns = static_cast<float>((now_ns / TabActivity::spinner_interval_ns) % TabActivity::spinner_steps) / TabActivity::spinner_steps;
  } else if (kind_ == TabActivity::Kind::progress) {
    fraction = motion_.sample(progress_, now_ns);
    if (progress_.state == PaneProgressState::indeterminate) {
      const auto frame = ProgressAnimation::indeterminate<platform::ProgressCosine>(now_ns);
      fraction = frame.fraction;
      turns = frame.turns;
    }
  }

  if (fraction_ != fraction || turns_ != turns) {
    fraction_ = fraction;
    turns_ = turns;
    update();
    if (!animation_notification_pending_) {
      animation_notification_pending_ = true;
      QMetaObject::invokeMethod(this, [this] {
        animation_notification_pending_ = false;
        emit animationChanged();
      },
                                Qt::QueuedConnection);
    }
  }
}

void NativeTabActivity::synchronize() {
  if (clock_) {
    clock_->requestSynchronization();
  }

  sample(clock_ ? clock_->now() : platform::AwakeClock::nowNanoseconds());
}

void NativeTabActivity::bindClock() {
  if (clock_) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (clock_) {
    clock_->attach(*this);
  }

  synchronize();
}

QSGNode *NativeTabActivity::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  if (window() == nullptr || width() <= 0 || height() <= 0 || kind_ == TabActivity::Kind::none) {
    const std::unique_ptr<QSGNode> retired{previous};

    return nullptr;
  }

  const auto density = window()->effectiveDevicePixelRatio();
  const auto ratio = static_cast<float>(ratio_ * density);
  const Color color{.r = color_.redF(), .g = color_.greenF(), .b = color_.blueF(), .a = color_.alphaF()};

  return paintRoundedShapes<ProgressCapsule::maximum_paints>(*this, previous, [&](auto append, Rect area) {
    if (kind_ == TabActivity::Kind::dot) {
      const auto side = std::min(TabActivity::dot_side * ratio, area.width);
      append(RoundedRectanglePaint{.origin = {.x = area.x + area.width - side, .y = area.y + ((area.height - side) / 2)}, .shape = RoundedRectangle::resolve({.x = side, .y = side}, {.fill = color, .radius = side / 2})});
    } else if (kind_ == TabActivity::Kind::spinner) {
      const auto side = std::min(TabActivity::spinner_side * ratio, area.width);
      ProgressRing{.area = {.x = area.x + area.width - side, .y = area.y + ((area.height - side) / 2), .width = side, .height = side}, .color = color, .fraction = fraction_, .rotation = turns_}.visit(append);
    } else if (kind_ == TabActivity::Kind::progress) {
      ProgressCapsule{.area = area, .color = color, .ratio = ratio, .state = progress_.state, .fraction = fraction_, .rotation = turns_, .compact = compact_}.visit(append);
    }
  });
}

void NativeTabActivity::itemChange(ItemChange change, const ItemChangeData &data) {
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

void NativeTabActivity::geometryChange(const QRectF &current, const QRectF &previous) {
  const QPointer<NativeTabActivity> alive{this};
  QQuickItem::geometryChange(current, previous);
  if (alive) {
    synchronize();
    if (alive) {
      update();
    }
  }
}

}
