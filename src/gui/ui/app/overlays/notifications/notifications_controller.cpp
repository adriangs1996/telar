#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "notifications_controller.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/timing/deadline_timer.hpp"
#include <QLatin1Char>
#include <QMetaObject>
#include <exception>
#include <limits>

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

  NotificationsController::NotificationsController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    timer_.setSingleShot(true);
    timer_.setTimerType(Qt::PreciseTimer);
    connect(&timer_, &QTimer::timeout, this, [this] {
      store_.session().advanceNotifications(system::AwakeClock::nowNanoseconds());
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
    const auto now_ns = system::AwakeClock::nowNanoseconds();

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

    store_.interact(
        [&] {
          if (store_.session().activateNotification(*id)) {
            if (!link.isEmpty()) {
              emit linkRequested(link);
            }

            refresh();
            emit focusRestoreRequested();
          }
        },
        [this](const std::exception& error) {
          emit failed(QString::fromUtf8(error.what()));
        }
    );
  }

  void NotificationsController::retireFocus(const QString& identity, QQuickItem* retiring_owner) {
    if (!resolve(identity)) {
      return;
    }

    const auto* pane = store_.session().focusedPane();
    if (pane == nullptr || !pane->attached || window_ == nullptr || (retiring_owner != nullptr && retiring_owner->window() != window_) || (!keyboardFocusVacant(*window_) && window_->activeFocusItem() != retiring_owner)) {
      return;
    }

    const NotificationFocus target{.window = window_generation_, .machine = store_.machineView(), .pane = pane->id, .generation = pane->generation, .attachment = pane->attachment_generation};

    // A delivered control can disappear before its disabled record is painted.
    // Complete its retirement before restoring the captured pane's keyboard owner.
    QMetaObject::invokeMethod(this, [this, target] {
      if (window_ == nullptr || store_.dialog().kind != Store::Dialog::none) {
        return;
      }

      const auto* current = store_.session().focusedPane();
      if (!keyboardFocusVacant(*window_) || current == nullptr || !current->attached) {
        return;
      }

      const NotificationFocus present{.window = window_generation_, .machine = store_.machineView(), .pane = current->id, .generation = current->generation, .attachment = current->attachment_generation};
      if (present == target) {
        emit focusRestoreRequested();
      }
    },
        Qt::QueuedConnection);
  }

  void NotificationsController::setWindow(QQuickWindow& window, std::uint64_t generation) {
    window_ = &window;
    window_generation_ = generation;
  }

}
