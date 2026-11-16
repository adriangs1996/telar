#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "notifications_controller.hpp"
#include "ui/app/deadline_timer.hpp"
#include "ui/app/projection.hpp"
#include <QLatin1Char>
#include <exception>
#include <limits>

import telar.gui.platform.awake_clock;

namespace telar::gui::qt {

  NotificationsController::NotificationsController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    timer_.setSingleShot(true);
    timer_.setTimerType(Qt::PreciseTimer);
    connect(&timer_, &QTimer::timeout, this, [this] {
      store_.session().advanceNotifications(platform::AwakeClock::nowNanoseconds());
      refresh();
    });
  }

  const NotificationCenter& NotificationsController::center() const noexcept {
    return store_.session().notifications();
  }

  QString NotificationsController::identity(NotificationId identity) const {
    return QString::number(store_.machineView()) + QLatin1Char(':') + QString::number(identity.value);
  }

  std::optional<NotificationId> NotificationsController::resolve(const QString& identity) const {
    const auto separator = identity.indexOf(QLatin1Char(':'));
    if (separator < 0) {
      return std::nullopt;
    }

    bool valid_view = false;
    bool valid_id = false;
    const auto view = identity.first(separator).toULongLong(&valid_view);
    const auto raw_id = identity.sliced(separator + 1).toULongLong(&valid_id);

    return valid_view && valid_id && view == store_.machineView() ? std::optional{NotificationId{raw_id}} : std::nullopt;
  }

  bool NotificationsController::targetVisible(NotificationTarget target) const noexcept {
    return store_.session().notificationTargetVisible(target);
  }

  Rect NotificationsController::host() const {
    const auto& geometry = display_.geometry;
    auto grid = grid_;

    grid.scale = 1;
    const auto size = grid.fit(geometry.terminal.width, geometry.terminal.height);

    return size ? Rect{.x = geometry.terminal.x, .y = geometry.terminal.y, .width = static_cast<float>(size->cols * grid.cell_width_px), .height = static_cast<float>(size->rows * grid.cell_height_px)} : Rect{};
  }

  const DisplayMetrics& NotificationsController::display() const noexcept {
    return display_;
  }

  std::uint64_t NotificationsController::machineView() const noexcept {
    return store_.machineView();
  }

  void NotificationsController::setDisplay(const DisplayMetrics& display, TerminalGrid grid) {
    display_ = display;
    grid_ = grid;
    emit displayChanged();
  }

  void NotificationsController::publish(NotificationInput input) {
    store_.session().publishNotification(input);
    refresh();
  }

  void NotificationsController::refresh() {
    presented_ = store_.session().notificationRevision();
    schedule();
    emit changed();
  }

  void NotificationsController::present() {
    if (store_.session().notificationRevision() != presented_) {
      refresh();
    }
  }

  void NotificationsController::publishView() {
    emit viewChanged();
  }

  void NotificationsController::schedule() {
    const auto now_ns = platform::AwakeClock::nowNanoseconds();

    scheduleDeadline(timer_, center().nextDeadline(now_ns, std::numeric_limits<std::uint64_t>::max()), now_ns);
  }

  void NotificationsController::dismiss(const QString& identity) {
    const auto id = resolve(identity);
    if (id && store_.session().dismissNotification(*id)) {
      refresh();
      emit focusRestoreRequested();
    }
  }

  void NotificationsController::activate(const QString& identity) {
    const auto id = resolve(identity);
    const auto* item = id ? center().find(*id) : nullptr;
    if (item == nullptr) {
      return;
    }

    const auto link = toQString(item->link.view());

    store_.begin();
    try {
      if (store_.session().activateNotification(*id)) {
        if (!link.isEmpty()) {
          emit linkRequested(link);
        }

        refresh();
        emit focusRestoreRequested();
      }
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));

      return;
    }

    store_.commit();
  }

  void NotificationsController::retireFocus(const QString& identity, QQuickItem* retiring_owner) {
    if (resolve(identity)) {
      emit focusRetireRequested(retiring_owner);
    }
  }

}
