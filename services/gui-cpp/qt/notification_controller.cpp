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
#include <QMetaObject>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QtCore/qchar.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <optional>

namespace telar::gui::qt {

namespace {

struct NotificationFocus {
  std::uint64_t window;
  std::uint64_t machine;
  std::uint64_t pane;
  std::uint64_t generation;
  std::uint64_t attachment;

  bool operator==(const NotificationFocus &) const = default;
};

bool keyboardFocusVacant(const QQuickWindow &window) {
  const auto *item = window.activeFocusItem();

  return item == nullptr || item == window.contentItem() || !item->isEnabled();
}

}

void Application::initializeNotifications() {
  notification_timer_.setSingleShot(true);
  notification_timer_.setTimerType(Qt::PreciseTimer);

  connect(&notification_timer_, &QTimer::timeout, this, [this] {
    session().advanceNotifications(platform::AwakeClock::nowNanoseconds());
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
  return session().notifications();
}

QString Application::notificationIdentity(NotificationId identity) const {
  return QString::number(machine_view_revision_) + QLatin1Char(':') + QString::number(identity.value);
}

std::optional<NotificationId> Application::resolveNotification(const QString &identity) const {
  const auto separator = identity.indexOf(QLatin1Char(':'));
  if (separator < 0) {
    return std::nullopt;
  }

  bool valid_view = false;
  bool valid_id = false;
  const auto view = identity.first(separator).toULongLong(&valid_view);
  const auto raw_id = identity.sliced(separator + 1).toULongLong(&valid_id);

  return valid_view && valid_id && view == machine_view_revision_ ? std::optional{NotificationId{raw_id}} : std::nullopt;
}

bool Application::notificationTargetVisible(NotificationTarget target) const noexcept {
  return session().notificationTargetVisible(target);
}

Rect Application::notificationHost(const DisplayMetrics &display) const {
  const auto &geometry = display.geometry;
  auto grid = terminal_grid_;
  grid.scale = 1;
  const auto size = grid.fit(geometry.terminal.width, geometry.terminal.height);

  return size ? Rect{.x = geometry.terminal.x, .y = geometry.terminal.y, .width = static_cast<float>(size->cols * grid.cell_width_px), .height = static_cast<float>(size->rows * grid.cell_height_px)} : Rect{};
}

void Application::publishNotification(NotificationInput input) {
  session().publishNotification(input);
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
      session().resumeGraphics();
    } catch (const std::exception &error) {
      fail(error);
    }

    refreshPanes();
    scheduleGraphicsRecovery();
  });
}

void Application::scheduleGraphicsRecovery() {
  scheduleDeadline(graphics_resume_timer_, session().ready() ? session().graphicsResumeDeadline() : std::nullopt, platform::AwakeClock::nowNanoseconds());
}

void Application::dismissNotification(const QString &identity) {
  const auto id = resolveNotification(identity);
  if (id && session().dismissNotification(*id)) {
    refreshNotifications();
    restoreTerminalFocus();
  }
}

void Application::activateNotification(const QString &identity) {
  const auto id = resolveNotification(identity);
  const auto *item = id ? notifications().find(*id) : nullptr;
  if (item == nullptr) {
    return;
  }

  const auto link = LinkTarget::fromUri(item->link.view());
  applyInteraction([&] {
    if (session().activateNotification(*id)) {
      if (link) {
        static_cast<void>(openLink(*link));
      }

      refreshNotifications();
      restoreTerminalFocus();
    }
  });
}

void Application::retireNotificationFocus(const QString &identity) {
  const auto *pane = session().focusedPane();
  if (!resolveNotification(identity) || pane == nullptr || !pane->attached || window_ == nullptr || !keyboardFocusVacant(*window_)) {
    return;
  }

  const NotificationFocus target{.window = window_generation_, .machine = machine_view_revision_, .pane = pane->id, .generation = pane->generation, .attachment = pane->attachment_generation};
  // Disabling a control can still be changing Qt focus while its binding runs.
  // Complete that transition before restoring the captured pane's keyboard owner.
  QMetaObject::invokeMethod(this, [this, target] {
    if (window_ == nullptr || !dialog_.isEmpty()) {
      return;
    }

    const auto *current = session().focusedPane();
    if (!keyboardFocusVacant(*window_) || current == nullptr || !current->attached) {
      return;
    }

    const NotificationFocus present{.window = window_generation_, .machine = machine_view_revision_, .pane = current->id, .generation = current->generation, .attachment = current->attachment_generation};
    if (present == target) {
      restoreTerminalFocus();
    }
  },
                            Qt::QueuedConnection);
}

void Application::restoreTerminalFocus() {
  const auto *pane = session().focusedPane();
  const auto terminal = pane != nullptr ? terminals_.value(pane->id) : nullptr;
  if (terminal && terminal->isVisible() && dialog_.isEmpty()) {
    terminal->forceActiveFocus(Qt::OtherFocusReason);
  }
}

}
