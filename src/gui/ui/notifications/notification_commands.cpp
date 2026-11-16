#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/terminal_size.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/foundation/timing/deadline_timer.hpp"
#include "ui/terminal/terminal_item.hpp"
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
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

import telar.gui.core.metrics;
import telar.gui.links.cell_links;
import telar.gui.platform.awake_clock;

namespace telar::gui::qt {

  namespace {

    struct NotificationFocus {
      std::uint64_t window;
      std::uint64_t machine;
      std::uint64_t pane;
      std::uint64_t generation;
      std::uint64_t attachment;

      bool operator==(const NotificationFocus&) const = default;
    };

    bool keyboardFocusVacant(const QQuickWindow& window) {
      const auto* item = window.activeFocusItem();

      return item == nullptr || item == window.contentItem() || !item->isEnabled();
    }

  }

  void ApplicationController::initializeNotifications() {
    connect(this, &ApplicationController::notification, this, [this](const QString& message) {
      const auto bytes = message.toUtf8();

      notifications_.publish({
          .title = "Telar",
          .message = {
              bytes.constData(),
              static_cast<std::size_t>(bytes.size()),
          },
          .link = {},
      });
    });
    connect(&notifications_, &NotificationsController::focusRestoreRequested, this, &ApplicationController::restoreTerminalFocus);
    connect(&notifications_, &NotificationsController::focusRetireRequested, this, &ApplicationController::retireNotificationFocus);
    connect(&notifications_, &NotificationsController::failed, this, &ApplicationController::reportFailure);
    connect(&notifications_, &NotificationsController::linkRequested, this, [this](const QString& uri) {
      const auto bytes = uri.toUtf8();

      if (const auto link = LinkTarget::fromUri({bytes.constData(), static_cast<std::size_t>(bytes.size())})) {
        static_cast<void>(openLink(*link));
      }
    });
  }

  void ApplicationController::initializeGraphicsRecovery() {
    graphics_resume_timer_.setSingleShot(true);
    graphics_resume_timer_.setTimerType(Qt::PreciseTimer);
    connect(&graphics_resume_timer_, &QTimer::timeout, this, [this] {
      try {
        session().resumeGraphics();
      } catch (const std::exception& error) {
        fail(error);
      }

      refreshPanes();
      scheduleGraphicsRecovery();
    });
  }

  void ApplicationController::scheduleGraphicsRecovery() {
    scheduleDeadline(graphics_resume_timer_, session().ready() ? session().graphicsResumeDeadline() : std::nullopt, platform::AwakeClock::nowNanoseconds());
  }

  void ApplicationController::retireNotificationFocus(QQuickItem* retiring_owner) {
    const auto* pane = session().focusedPane();
    if (pane == nullptr || !pane->attached || window_ == nullptr || (retiring_owner != nullptr && retiring_owner->window() != window_) || (!keyboardFocusVacant(*window_) && window_->activeFocusItem() != retiring_owner)) {
      return;
    }

    const NotificationFocus target{.window = window_generation_, .machine = store_.machineView(), .pane = pane->id, .generation = pane->generation, .attachment = pane->attachment_generation};

    // A delivered control can disappear before its disabled record is painted.
    // Complete its retirement before restoring the captured pane's keyboard owner.
    QMetaObject::invokeMethod(this, [this, target] {
      if (window_ == nullptr || store_.dialog().kind != Dialog::none) {
        return;
      }

      const auto* current = session().focusedPane();
      if (!keyboardFocusVacant(*window_) || current == nullptr || !current->attached) {
        return;
      }

      const NotificationFocus present{.window = window_generation_, .machine = store_.machineView(), .pane = current->id, .generation = current->generation, .attachment = current->attachment_generation};
      if (present == target) {
        restoreTerminalFocus();
      }
    },
        Qt::QueuedConnection);
  }

  void ApplicationController::restoreTerminalFocus() {
    const auto* pane = session().focusedPane();
    const auto terminal = pane != nullptr ? terminals_.value(pane->id) : nullptr;
    if (terminal && terminal->isVisible() && store_.dialog().kind == Dialog::none) {
      terminal->forceActiveFocus(Qt::OtherFocusReason);
    }
  }

}
