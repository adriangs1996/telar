#include "window_animation_clock.hpp"
#include "core/configuration.hpp"
#include "history_loading_layout.hpp"
#include "history_selection_layout.hpp"
#include "modal_reveal_layout.hpp"
#include "native_agent_status.hpp"
#include "native_pane_attention.hpp"
#include "native_tab_activity.hpp"
#include "notification_layout.hpp"
#include "platform/awake_clock.hpp"
#include "presentation/attention_fades.hpp"
#include "presentation/frame_pacer.hpp"
#include <QEvent>
#include <QObject>
#include <QQuickWindow>
#include <QScreen>
#include <QString>
#include <QTimer>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <tuple>

namespace telar::gui::qt {

WindowAnimationClock::WindowAnimationClock(QQuickWindow &window)
    : QObject(&window),
      window_(window),
      timer_(this) {
  timer_.setObjectName(QStringLiteral("agentStatusAnimation"));
  timer_.setSingleShot(true);
  timer_.setTimerType(Qt::PreciseTimer);
  connect(&timer_, &QTimer::timeout, this, [this] {
    if (sampleVisible(now())) {
      synchronize();
    }
  });
  window.installEventFilter(this);
  connect(&window, &QWindow::visibilityChanged, this, [this] {
    requestSynchronization();
  });
  connect(&window, &QQuickWindow::afterAnimating, this, [this] {
    if (!synchronization_pending_ && !deadline_ns_) {
      return;
    }

    const auto timestamp = now();
    if (synchronization_pending_ || (deadline_ns_ && timestamp >= *deadline_ns_)) {
      if (sampleVisible(timestamp)) {
        synchronize();
      }
    }
  });
}

WindowAnimationClock &WindowAnimationClock::forWindow(QQuickWindow &window) {
  for (auto *child : window.children()) {
    if (auto *clock = dynamic_cast<WindowAnimationClock *>(child)) {
      return *clock;
    }
  }

  return *std::make_unique<WindowAnimationClock>(window).release();
}

std::uint64_t WindowAnimationClock::now() noexcept {
  now_ns_ = std::max(now_ns_, platform::AwakeClock::nowNanoseconds());

  return now_ns_;
}

std::uint64_t WindowAnimationClock::frameInterval() const noexcept {
  constexpr double default_refresh_rate = Configuration::default_fps;
  constexpr double nanoseconds_per_second = FramePacer::nanoseconds_per_second;
  const auto *screen = window_.screen();
  const auto reported = screen == nullptr ? default_refresh_rate : screen->refreshRate();
  const auto rate = std::isfinite(reported) && reported > 0 ? reported : default_refresh_rate;

  const auto display_interval_ns = static_cast<std::uint64_t>(std::clamp(std::ceil(nanoseconds_per_second / rate), 1.0, nanoseconds_per_second));

  return FramePacer::resolveInterval(display_interval_ns, maximum_fps_);
}

void WindowAnimationClock::setMaximumFrameRate(std::optional<std::uint16_t> maximum_fps) {
  if (maximum_fps_ == maximum_fps) {
    return;
  }

  maximum_fps_ = maximum_fps;
  requestSynchronization();
}

AttentionFrame WindowAnimationClock::sampleAttention(PaneAttentionKey key, std::uint64_t now_ns) noexcept {
  return attention_.sample(key, now_ns, frameInterval());
}

void WindowAnimationClock::requestSynchronization() {
  if (synchronization_pending_) {
    return;
  }

  synchronization_pending_ = true;
  QTimer::singleShot(std::chrono::nanoseconds::zero(), this, [this] {
    synchronization_pending_ = false;
    if (sampleVisible(now())) {
      synchronize();
    }
  });
}

bool WindowAnimationClock::eventFilter(QObject *watched, QEvent *event) {
  if (event->type() == QEvent::Expose) {
    if (!sampleVisible(now())) {
      return true;
    }

    requestSynchronization();
  }

  return QObject::eventFilter(watched, event);
}

bool WindowAnimationClock::sampleVisible(std::uint64_t timestamp) {
  const bool exposed = window_.isVisible() && window_.isExposed() && window_.visibility() != QWindow::Minimized;
  if (exposed) {
    attention_.begin();
  }

  const auto alive = std::apply([&](const auto &...items) {
    return (sampleItems(items, timestamp, exposed) && ...);
  },
                                items_);
  if (!alive) {
    return false;
  }

  if (exposed) {
    attention_.end();
  }

  return true;
}

void WindowAnimationClock::synchronize() {
  timer_.stop();
  deadline_ns_.reset();
  if (!window_.isVisible() || !window_.isExposed() || window_.visibility() == QWindow::Minimized) {
    return;
  }

  const auto timestamp = now();
  std::optional<std::uint64_t> earliest;
  std::apply([&](const auto &...items) {
    for (const auto deadline : {nextDeadline(items, timestamp)...}) {
      if (deadline && (!earliest || *deadline < *earliest)) {
        earliest = deadline;
      }
    }
  },
             items_);

  if (earliest) {
    deadline_ns_ = earliest;
    constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
    const auto delta = *earliest > timestamp ? *earliest - timestamp : 0;
    const auto delay = (delta / nanoseconds_per_millisecond) + static_cast<std::uint64_t>(delta % nanoseconds_per_millisecond != 0);
    timer_.start(static_cast<int>(std::clamp<std::uint64_t>(delay, 1, std::numeric_limits<int>::max())));
  }
}

}
