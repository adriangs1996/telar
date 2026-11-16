#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include <QByteArray>
#include <QString>
#include <cstddef>

import telar.gui.links.cell_links;

namespace telar::gui::qt {

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
    connect(&notifications_, &NotificationsController::failed, this, &ApplicationController::reportFailure);
    connect(&notifications_, &NotificationsController::linkRequested, this, [this](const QString& uri) {
      const auto bytes = uri.toUtf8();

      if (const auto link = LinkTarget::fromUri({bytes.constData(), static_cast<std::size_t>(bytes.size())})) {
        static_cast<void>(links_.open(*link));
      }
    });
  }

}
