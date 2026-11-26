#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "window_animation_clock.hpp"
#include "tbc/annotations.hpp"
#include <QEvent>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QScreen>
#include <QString>
#include <QTimer>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <span>

import telar.gui.foundation.core;
import telar.gui.foundation.system;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    struct TBC_SHARED Composition {
      std::span<const WindowAnimationLane::Make> lanes;
    };

    std::span<const WindowAnimationLane::Make>& composition() noexcept {
      static Composition state;

      return state.lanes;
    }

  }

  WindowAnimationClock::WindowAnimationClock(QQuickWindow& window)
      : QObject(&window),
        window_(window),
        timer_(this) {
    lanes_.reserve(composition().size());
    for (const auto make : composition()) {
      lanes_.push(make(adapter_));
    }

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

  WindowAnimationClock& WindowAnimationClock::forWindow(QQuickWindow& window) {
    for (auto* child : window.children()) {
      if (auto* clock = dynamic_cast<WindowAnimationClock*>(child)) {
        return *clock;
      }
    }

    return *std::make_unique<WindowAnimationClock>(window).release();
  }

  void WindowAnimationClock::compose(std::span<const WindowAnimationLane::Make> lanes) noexcept {
    composition() = lanes;
  }

  std::uint64_t WindowAnimationClock::now() noexcept {
    now_ns_ = std::max(now_ns_, system::AwakeClock::nowNanoseconds());

    return now_ns_;
  }

  std::uint64_t WindowAnimationClock::frameInterval() const noexcept {
    constexpr double default_refresh_rate = Configuration::default_fps;
    constexpr double nanoseconds_per_second = application::window::FramePacer::nanoseconds_per_second;
    const auto* screen = window_.screen();
    const auto reported = screen == nullptr ? default_refresh_rate : screen->refreshRate();
    const auto rate = std::isfinite(reported) && reported > 0 ? reported : default_refresh_rate;

    const auto display_interval_ns = static_cast<std::uint64_t>(std::clamp(std::ceil(nanoseconds_per_second / rate), 1.0, nanoseconds_per_second));

    return application::window::FramePacer::resolveInterval(display_interval_ns, maximum_fps_);
  }

  void WindowAnimationClock::setMaximumFrameRate(ds::Option<std::uint16_t> maximum_fps) {
    if (maximum_fps_ == maximum_fps) {
      return;
    }

    maximum_fps_ = maximum_fps;
    requestSynchronization();
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

  bool WindowAnimationClock::eventFilter(QObject* watched, QEvent* event) {
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
    const QPointer<WindowAnimationClock> alive{this};

    // A lane may start while another samples, which moves the vector: index it again after
    // each call.
    // NOLINTNEXTLINE(modernize-loop-convert): a range-for would keep the moved storage.
    for (std::size_t index = 0; index < lanes_.size(); ++index) {
      const auto& lane = lanes_[index];
      if (!lane.sample(lane.items.get(), timestamp, exposed, alive)) {
        return false;
      }
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
    ds::Option<std::uint64_t> earliest;

    for (const auto& lane : lanes_) {
      const auto deadline = lane.deadline(lane.items.get(), timestamp);
      if (deadline && (!earliest || *deadline < *earliest)) {
        earliest = deadline;
      }
    }

    if (earliest) {
      deadline_ns_ = earliest;
      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
      const auto delta = *earliest > timestamp ? *earliest - timestamp : 0;
      const auto delay = (delta / nanoseconds_per_millisecond) + static_cast<std::uint64_t>(delta % nanoseconds_per_millisecond != 0);

      timer_.start(static_cast<int>(std::clamp<std::uint64_t>(delay, 1, std::numeric_limits<int>::max())));
    }
  }

}
