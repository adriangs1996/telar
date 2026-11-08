#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <concepts>
#include <cstdint>
#include "../platform/window.hpp"
#include <algorithm>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_cells.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <QCoreApplication>
#include <QEvent>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QTimer>
#include <QWindow>
#include <memory>
#include <utility>

#pragma once
#include "platform/window.hpp"


import telar.gui.core.unicode_scalar;
import telar.gui.platform.profile_file;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

template <typename Window>
concept FramePacingWindow = std::derived_from<Window, QObject> && requires(const Window &window) {
  { window.isVisible() } -> std::same_as<bool>;
  { window.isExposed() } -> std::same_as<bool>;
  { window.visibility() } -> std::same_as<QWindow::Visibility>;
};

template <MonotonicClock Clock = platform::AwakeClock, FramePacingWindow Window = QQuickWindow>
class WindowFramePacer final {
public:
  explicit WindowFramePacer(Window &window)
      : window_(&window) {
    deadline_.setSingleShot(true);
    deadline_.setTimerType(Qt::PreciseTimer);
    QObject::connect(&deadline_, &QTimer::timeout, &deadline_, [this] {
      const bool requested = std::exchange(pending_, false);
      if (!visible() || !requested) {
        return;
      }

      if constexpr (std::derived_from<Window, QWindow>) {
        if (delivery_ == Delivery::platform) {
          platform::deliverPendingWindowUpdate(*window_);

          return;
        }
      }

      QEvent request{QEvent::UpdateRequest};
      QCoreApplication::sendEvent(window_, &request);
    });
    QObject::connect(&window, &QObject::destroyed, &deadline_, [this] {
      pending_ = false;
      deadline_.stop();
    });
  }

  ~WindowFramePacer() {
    if (window_ && pending_ && delivery_ == Delivery::held) {
      QCoreApplication::postEvent(window_, std::make_unique<QEvent>(QEvent::UpdateRequest).release());
    }
  }

  WindowFramePacer(const WindowFramePacer &) = delete;
  WindowFramePacer &operator=(const WindowFramePacer &) = delete;
  WindowFramePacer(WindowFramePacer &&) = delete;
  WindowFramePacer &operator=(WindowFramePacer &&) = delete;

  void configure(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) {
    const auto previous = pacer_.interval();
    const auto interval = pacer_.configure(display_interval_ns, maximum_fps);
    if (pending_ && interval != previous) {
      deadline_.start(immediate_delivery_ms);
    }
  }

  void noteInput(FramePacer::Pane pane, std::uint64_t now_ns) {
    pacer_.noteInput(pane, now_ns);
    if (pending_) {
      deadline_.start(immediate_delivery_ms);
    }
  }

  void record(std::span<const FramePacer::Pane> panes, std::uint64_t now_ns) noexcept {
    pacer_.record(panes, now_ns);
  }

  [[nodiscard]] bool pending() const noexcept {
    return pending_;
  }

  bool defer(std::span<const FramePacer::Pane> panes) {
    if (!visible()) {
      pending_ = false;
      deadline_.stop();

      return false;
    }

    const auto now_ns = Clock::nowNanoseconds();
    if (const auto deadline = pacer_.waitUntil(panes, now_ns)) {
      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
      const auto remaining = *deadline - now_ns;
      const auto milliseconds = (remaining / nanoseconds_per_millisecond) + static_cast<std::uint64_t>(remaining % nanoseconds_per_millisecond != 0);
      delivery_ = Delivery::held;
      pending_ = true;
      deadline_.start(static_cast<int>(std::min<std::uint64_t>(milliseconds, std::numeric_limits<int>::max())));

      return true;
    }

    pending_ = false;
    deadline_.stop();

    return false;
  }

  void requestInputFrame(FramePacer::Pane pane) {
    if constexpr (std::derived_from<Window, QWindow>) {
      if (!platform::supportsImmediateWindowUpdates()) {
        return;
      }
    }

    if (!visible()) {
      pending_ = false;
      deadline_.stop();

      return;
    }

    if (!pacer_.canAdvanceInput(pane, Clock::nowNanoseconds())) {
      return;
    }

    if (!pending_) {
      delivery_ = Delivery::platform;
      pending_ = true;
    }

    deadline_.start(immediate_delivery_ms);
  }

  void reconsider(std::span<const FramePacer::Pane> panes) {
    if (pending_ && !pacer_.waitUntil(panes, Clock::nowNanoseconds())) {
      deadline_.start(immediate_delivery_ms);
    }
  }

private:
  enum class Delivery : std::uint8_t {
    held,
    platform,
  };

  static constexpr int immediate_delivery_ms = 0;

  [[nodiscard]] bool visible() const {
    return window_ && window_->isVisible() && window_->isExposed() && window_->visibility() != QWindow::Minimized;
  }

  QPointer<Window> window_;
  FramePacer pacer_;
  QTimer deadline_;
  Delivery delivery_ = Delivery::held;
  bool pending_ = false;
};

}
