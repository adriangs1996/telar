#include "application.hpp"
#include "application/notification_center.hpp"
#include "application/notification_item.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "deadline_timer.hpp"
#include "links/link_target.hpp"
#include "platform/awake_clock.hpp"
#include "presentation/display_metrics.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "terminal_item.hpp"
#include <QByteArray>
#include <QObject>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <optional>

namespace telar::gui::qt {

void Application::initializeNotifications() {
  notification_timer_.setSingleShot(true);
  notification_timer_.setTimerType(Qt::PreciseTimer);

  connect(&notification_timer_, &QTimer::timeout, this, [this] {
    session_.advanceNotifications(platform::AwakeClock::nowNanoseconds());
    refreshNotifications();
  });

  connect(this, &Application::notification, this, [this](const QString &message) {
    const auto bytes = message.toUtf8();

    publishNotification({
        .title = "Telar",
        .message = {
            bytes.constData(),
            static_cast<std::size_t>(bytes.size()),
        },
        .link = {},
    });
  });
}

const NotificationCenter &Application::notifications() const noexcept {
  return session_.notifications();
}

bool Application::notificationTargetVisible(NotificationTarget target) const noexcept {
  return session_.notificationTargetVisible(target);
}

Rect Application::notificationHost(const DisplayMetrics &display) const {
  const auto &geometry = display.geometry;
  auto grid = terminal_grid_;
  grid.scale = 1;
  const auto size = grid.fit(geometry.terminal.width, geometry.terminal.height);

  return size ? Rect{.x = geometry.terminal.x, .y = geometry.terminal.y, .width = static_cast<float>(size->cols * grid.cell_width_px), .height = static_cast<float>(size->rows * grid.cell_height_px)} : Rect{};
}

void Application::publishNotification(NotificationInput input) {
  session_.publishNotification(input);
  refreshNotifications();
}

void Application::refreshNotifications() {
  scheduleNotifications();
  emit notificationsChanged();
}

void Application::scheduleNotifications() {
  const auto now_ns = platform::AwakeClock::nowNanoseconds();
  scheduleDeadline(notification_timer_, notifications().nextDeadline(now_ns, std::numeric_limits<std::uint64_t>::max()), now_ns);
}

void Application::initializeGraphicsRecovery() {
  graphics_resume_timer_.setSingleShot(true);
  graphics_resume_timer_.setTimerType(Qt::PreciseTimer);
  connect(&graphics_resume_timer_, &QTimer::timeout, this, [this] {
    try {
      session_.resumeGraphics();
    } catch (const std::exception &error) {
      fail(error);
    }

    refreshPanes();
    scheduleGraphicsRecovery();
  });
}

void Application::scheduleGraphicsRecovery() {
  scheduleDeadline(graphics_resume_timer_, session_.ready() ? session_.graphicsResumeDeadline() : std::nullopt, platform::AwakeClock::nowNanoseconds());
}

void Application::dismissNotification(const QString &identity) {
  bool valid = false;
  const NotificationId id{identity.toULongLong(&valid)};
  if (valid && session_.dismissNotification(id)) {
    refreshNotifications();
    restoreTerminalFocus();
  }
}

void Application::activateNotification(const QString &identity) {
  bool valid = false;
  const NotificationId id{identity.toULongLong(&valid)};
  const auto *item = valid ? notifications().find(id) : nullptr;
  if (item == nullptr) {
    return;
  }

  const auto link = LinkTarget::fromUri(item->link.view());
  applyInteraction([&] {
    if (session_.activateNotification(id)) {
      if (link) {
        static_cast<void>(openLink(*link));
      }

      refreshNotifications();
      restoreTerminalFocus();
    }
  });
}

void Application::restoreTerminalFocus() {
  const auto *pane = session_.focusedPane();
  const auto terminal = pane != nullptr ? terminals_.value(pane->id) : nullptr;
  if (terminal && terminal->isVisible() && dialog_.isEmpty()) {
    terminal->forceActiveFocus(Qt::OtherFocusReason);
  }
}

}
