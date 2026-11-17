#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "pointer_dispatcher.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "platform/scroll_event.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include "ui/app/chrome/activity/activity_controller.hpp"
#include "ui/app/chrome/tabs/tabs_controller.hpp"
#include "ui/app/panes/attachments/attachment_shelf.hpp"
#include "ui/app/panes/attachments/attachments_controller.hpp"
#include "ui/app/panes/terminal/history/history_controller.hpp"
#include "ui/app/panes/terminal/terminal_controller.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/foundation/input/mouse_buttons.hpp"
#include "ui/foundation/input/native_pointer_events.hpp"
#include "ui/foundation/store/store.hpp"
#include "window_display.hpp"
#include <QCoreApplication>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QQuickWindow>
#include <QScopedValueRollback>
#include <QString>
#include <QWheelEvent>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>

import telar.gui.input.child_mouse;
import telar.gui.presentation.history_pointer;
import telar.gui.application;

namespace telar::gui::qt {

  PointerDispatcher::PointerDispatcher(WindowDisplay& display, ApplicationAllocator& memory, Store& store, TabsController& tabs, HistoryController& history, ActivityController& activity, AttachmentsController& attachments, TerminalController& terminals)
      : display_(display),
        store_(store),
        tabs_(tabs),
        history_(history),
        activity_(activity),
        attachments_(attachments),
        terminals_(terminals),
        native_events_(memory),
        history_scroll_events_(*this) {}

  void PointerDispatcher::setWindow(QQuickWindow& window) {
    if (window_ != nullptr) {
      cancel();
      window_->removeEventFilter(this);
      window_->disconnect(this);
    }

    window_ = &window;
    history_scroll_events_.setActive(true);

    activity_.observePointer(false);
    window.installEventFilter(this);
    connect(&window, &QWindow::activeChanged, this, [this] {
      if (window_ != nullptr && !window_->isActive()) {
        activity_.observePointer(false);
        cancel();
      }
    });
  }

  // Cocoa's native phase keeps fractional scroll across momentum and distinguishes
  // cancellation before Qt merges those phases into its wheel-event stream.
  bool PointerDispatcher::handleNativeScroll(std::string_view event_type, const void* message) {
    // The prompt line scrolls its own rows; the modal takes the wheel only while it shows.
    if (window_.isNull() || store_.dialog().kind != Store::Dialog::history || history_.hosted()) {
      return false;
    }

    const auto input = platform::nativeScrollInput(event_type, message, *window_);
    if (!input) {
      return false;
    }

    if (input->valid) {
      terminals_.retireScroll();
      history_.scroll({.x = input->x, .y = input->y}, input->sample);
    }

    return true;
  }

  HistoryActionCapture* PointerDispatcher::capture(Qt::MouseButton button) noexcept {
    const auto semantic = mouseButton(button);

    return semantic == MouseButton::none ? nullptr : &captures_[static_cast<std::size_t>(semantic)];
  }

  bool PointerDispatcher::occupied() const noexcept {
    return terminals_.holdsPointer() || std::ranges::any_of(captures_, &HistoryActionCapture::held);
  }

  void PointerDispatcher::presentHistoryActions(const HistoryActionSurface& surface) {
    for (auto& lease : captures_) {
      if (lease.held()) {
        lease.present(surface);
      }
    }
  }

  void PointerDispatcher::cancel() {
    tabs_.observeHover(std::nullopt);
    tabs_.cancelDrag();
    history_.retireHover();
    for (auto& lease : captures_) {
      lease.cancel();
    }

    terminals_.cancelPointer();
  }

  void PointerDispatcher::ungrab(TerminalItem& terminal) {
    if (handing_off_) {
      return;
    }

    terminal.releaseMouse();
    if (terminal.isVisible() && terminal.window() == window_) {
      cancel();
    }
  }

  bool PointerDispatcher::press(QMouseEvent& event) {
    if (tabs_.press(event, display_.chromeRatio())) {
      return false;
    }

    history_.observeHover(event.position(), HistoryHover::Observation::point);
    if (auto* lease = capture(event.button())) {
      if (lease->held()) {
        *lease = {};
      }

      const auto& surface = history_.presentedActions();
      HistoryActionCapture history;
      if (store_.dialog().kind == Store::Dialog::history && surface.generation == store_.dialog().generation && history.begin(surface, {.x = event.position().x() * surface.scale, .y = event.position().y() * surface.scale}, event.button() == Qt::LeftButton)) {
        // The history takes the button from a terminal that held it.
        *lease = history;
        terminals_.release(event.button());

        return true;
      }
    }

    if (!occupied() || qobject_cast<TerminalItem*>(event.exclusiveGrabber(event.point(0))) == nullptr) {
      return false;
    }

    const QScopedValueRollback handoff{handing_off_, true};

    event.setExclusiveGrabber(event.point(0), nullptr);
    const QScopedValueRollback delivery{delivering_, true};

    QCoreApplication::sendEvent(window_, &event);

    return true;
  }

  bool PointerDispatcher::move(QMouseEvent& event) {
    if (native_events_.moving()) {
      attachments_.shelf()->observePointer(event.position());
      history_.observeHover(event.position(), event.buttons() == Qt::NoButton ? HistoryHover::Observation::point : HistoryHover::Observation::retained);
    }

    activity_.observePointer(true, event.position());
    const auto tab_consumed = tabs_.drag(event, false);

    if (!occupied()) {
      return tab_consumed;
    }

    terminals_.dragPointer(event);

    const auto* grabber = event.exclusiveGrabber(event.point(0));

    return tab_consumed || grabber == nullptr || qobject_cast<const TerminalItem*>(grabber) != nullptr;
  }

  bool PointerDispatcher::release(QMouseEvent& event) {
    if (event.button() == Qt::LeftButton && tabs_.drag(event, true)) {
      return true;
    }

    if (auto* lease = capture(event.button()); lease != nullptr && lease->held()) {
      auto previous = std::exchange(*lease, HistoryActionCapture{});
      const auto& surface = history_.presentedActions();
      const auto action = previous.release(surface, {.x = event.position().x() * surface.scale, .y = event.position().y() * surface.scale});
      const auto choice = surface.choice;

      if (store_.dialog().kind != Store::Dialog::history || surface.generation != store_.dialog().generation) {
        return true;
      }

      if (action && choice) {
        history_.activate(*action, *choice);
      }

      return true;
    }

    if (!terminals_.releasePointer(event)) {
      return false;
    }

    const auto* grabber = qobject_cast<TerminalItem*>(event.exclusiveGrabber(event.point(0)));
    if (grabber != nullptr && event.buttons() == Qt::NoButton) {
      event.setExclusiveGrabber(event.point(0), nullptr);
    }

    return grabber != nullptr || event.exclusiveGrabber(event.point(0)) == nullptr;
  }

  bool PointerDispatcher::eventFilter(QObject* watched, QEvent* event) {
    if (delivering_ || watched != window_) {
      return false;
    }

    try {
      switch (event->type()) {
      case QEvent::Wheel:
        if (store_.dialog().kind == Store::Dialog::history) {
          terminals_.retireScroll();
        }

        return history_.handleWheel(dynamic_cast<QWheelEvent&>(*event));
      case QEvent::MouseButtonPress:
      case QEvent::MouseButtonDblClick: {
        auto& mouse = dynamic_cast<QMouseEvent&>(*event);

        activity_.observePointer(true, mouse.position());
        tabs_.observeHover(mouse.position());

        return press(mouse);
      }
      case QEvent::MouseMove: {
        auto& mouse = dynamic_cast<QMouseEvent&>(*event);

        tabs_.observeHover(mouse.position());
        return move(mouse);
      }
      case QEvent::ShortcutOverride:
      case QEvent::KeyPress:
      case QEvent::KeyRelease: {
        return tabs_.key(dynamic_cast<QKeyEvent&>(*event));
      }
      case QEvent::Leave:
        tabs_.leave();
        history_.retireHover();
        attachments_.shelf()->observePointer(std::nullopt);
        activity_.observePointer(false);
        return false;
      case QEvent::MouseButtonRelease: {
        auto& mouse = dynamic_cast<QMouseEvent&>(*event);

        tabs_.observeHover(mouse.position());
        return release(mouse);
      }
      default:
        return false;
      }
    } catch (const std::exception& error) {
      cancel();
      emit failed(QString::fromUtf8(error.what()));

      return true;
    }
  }

}
