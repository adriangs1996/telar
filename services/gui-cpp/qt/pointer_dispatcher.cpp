#include "pointer_dispatcher.hpp"
#include "application.hpp"
#include "attachment_shelf.hpp"
#include "native_pointer_events.hpp"
#include "application/records.hpp"
#include "input/child_mouse.hpp"
#include "input/mouse_encoder.hpp"
#include "links/link_gesture.hpp"
#include "mouse_buttons.hpp"
#include "terminal_item.hpp"
#include <QCoreApplication>
#include <QMouseEvent>
#include <QQuickWindow>
#include <QScopedValueRollback>
#include <QWindow>
#include <QWheelEvent>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <utility>

namespace telar::gui::qt {

PointerDispatcher::PointerDispatcher(Application &application)
    : QObject(&application),
      application_(application),
      native_events_(application.memory_) {
  connect(&application, &Application::inputReleasing, this, &PointerDispatcher::cancelPane);
}

void PointerDispatcher::setWindow(QQuickWindow &window) {
  if (window_ != nullptr) {
    cancel();
    window_->removeEventFilter(this);
    window_->disconnect(this);
  }

  window_ = &window;
  application_.observeActivityPointer(false);
  window.installEventFilter(this);
  connect(&window, &QWindow::activeChanged, this, [this] {
    if (window_ != nullptr && !window_->isActive()) {
      application_.observeActivityPointer(false);
      cancel();
    }
  });
}

PointerDispatcher::Capture *PointerDispatcher::capture(Qt::MouseButton button) noexcept {
  const auto semantic = mouseButton(button);

  return semantic == MouseButton::none ? nullptr : &captures_[static_cast<std::size_t>(semantic)];
}

bool PointerDispatcher::occupied() const noexcept {
  return std::ranges::any_of(captures_, &Capture::held);
}

void PointerDispatcher::acquire(TerminalItem &terminal, Qt::MouseButton button) {
  if (auto *lease = capture(button)) {
    *lease = {.terminal = &terminal, .pane_id = terminal.paneIdentity(), .held = true};
  }
}

void PointerDispatcher::beginChild(const ChildMouseView &view, ChildMouseSample sample) {
  if (sample.button == MouseButton::none) {
    return;
  }

  auto &lease = captures_[static_cast<std::size_t>(sample.button)];
  lease.child.begin(view, sample);
  report(lease.pane_id, ChildMouseProjection::project(view, sample));
}

ChildMouseView PointerDispatcher::view(const Capture &lease) const {
  if (const auto terminal = application_.terminals_.value(lease.pane_id); terminal != nullptr) {
    return terminal->childMouseView();
  }

  const auto *current = application_.pane(lease.pane_id);
  if (current == nullptr) {
    return {};
  }

  ChildMouseView result{.pane_id = current->id, .location = current->location, .protocol = current->screen.mouse(), .columns = current->screen.columns(), .rows = current->screen.rows(), .cell_width_px = current->size.cell_width_px, .cell_height_px = current->size.cell_height_px, .attached = current->attached, .visible = false};
  result.surface.attachment_generation = current->attachment_generation;

  return result;
}

ChildMouseSample PointerDispatcher::sample(const QMouseEvent &event, MousePhase phase, MouseButton button) {
  return {.button = button, .phase = phase, .position = {.x = static_cast<float>(event.position().x()), .y = static_cast<float>(event.position().y())}, .modifiers = TerminalItem::mouseModifiers(event.modifiers())};
}

void PointerDispatcher::report(std::uint64_t pane_id, const std::optional<ChildMouseReport> &report) {
  if (!report) {
    return;
  }

  MouseEncoder encoder;
  const auto packet = encoder.encode(report->button, report->x, report->y, report->released, true);
  application_.input(pane_id, QByteArray{packet.data(), static_cast<qsizetype>(packet.size())}, PaneInputSource::mouse);
}

void PointerDispatcher::release(Qt::MouseButton button) {
  if (auto *lease = capture(button)) {
    *lease = {};
  }
}

void PointerDispatcher::abandon(TerminalItem &terminal) {
  for (auto &lease : captures_) {
    if (lease.terminal == &terminal) {
      lease.terminal.clear();
    }
  }
}

void PointerDispatcher::cancelPane(std::uint64_t pane_id) {
  for (auto &lease : captures_) {
    if (lease.pane_id == pane_id) {
      if (lease.child.owned()) {
        report(pane_id, lease.child.cancel(view(lease)));
      }

      lease.terminal.clear();
    }
  }
}

void PointerDispatcher::cancel() {
  const auto previous_recipients = recipients();
  for (auto &lease : captures_) {
    if (lease.child.owned()) {
      report(lease.pane_id, lease.child.cancel(view(lease)));
    }

    lease.terminal.clear();
  }

  for (const auto &recipient : previous_recipients) {
    if (recipient.terminal != nullptr) {
      recipient.terminal->releaseMouse();
    }
  }
}

void PointerDispatcher::ungrab(TerminalItem &terminal) {
  if (handing_off_) {
    return;
  }

  terminal.releaseMouse();
  if (terminal.isVisible() && terminal.window() == window_) {
    cancel();
  }
}

PointerDispatcher::Recipients PointerDispatcher::recipients() const {
  Recipients result;
  for (const auto &[native, semantic] : mouse_buttons) {
    const auto &lease = captures_[static_cast<std::size_t>(semantic)];
    if (!lease.held || lease.terminal == nullptr) {
      continue;
    }

    auto *recipient = std::ranges::find(result, lease.terminal, &Recipient::terminal);
    if (recipient == result.end()) {
      recipient = std::ranges::find(result, QPointer<TerminalItem>{}, &Recipient::terminal);
      if (recipient == result.end()) {
        continue;
      }

      recipient->terminal = lease.terminal;
    }

    auto &buttons = lease.child.owned() ? recipient->child_buttons : recipient->view_buttons;
    buttons.setFlag(native);
  }

  return result;
}

void PointerDispatcher::deliver(TerminalItem &terminal, const QMouseEvent &event, Qt::MouseButtons buttons) {
  QMouseEvent forwarded{event.type(), terminal.mapFromScene(event.position()), event.position(), event.globalPosition(), event.button(), buttons, event.modifiers(), event.source(), event.pointingDevice()};
  forwarded.setTimestamp(event.timestamp());
  QCoreApplication::sendEvent(&terminal, &forwarded);
}

bool PointerDispatcher::press(QMouseEvent &event) {
  if (!occupied() || qobject_cast<TerminalItem *>(event.exclusiveGrabber(event.point(0))) == nullptr) {
    return false;
  }

  const QScopedValueRollback handoff{handing_off_, true};
  event.setExclusiveGrabber(event.point(0), nullptr);
  const QScopedValueRollback delivery{delivering_, true};
  QCoreApplication::sendEvent(window_, &event);

  return true;
}

bool PointerDispatcher::move(QMouseEvent &event) {
  if (native_events_.moving()) {
    application_.attachments_.observePointer(event.position());
  }

  application_.observeActivityPointer(true, event.position());

  if (!occupied()) {
    return false;
  }

  const auto destinations = recipients();
  for (const auto &destination : destinations) {
    if (destination.terminal != nullptr && (destination.child_buttons & event.buttons()) != Qt::NoButton) {
      destination.terminal->observeLinkPointer(destination.terminal->mapFromScene(event.position()), event.modifiers());
      if (destination.child_buttons.testFlag(Qt::LeftButton)) {
        destination.terminal->link_gesture_.cancel();
      }
    }
  }

  for (const auto &[native, semantic] : mouse_buttons) {
    auto &lease = captures_[static_cast<std::size_t>(semantic)];
    if (lease.held && lease.child.owned() && event.buttons().testFlag(native)) {
      report(lease.pane_id, lease.child.deliver(view(lease), sample(event, MousePhase::drag, semantic)));
    }
  }

  for (const auto &recipient : destinations) {
    const auto held = recipient.view_buttons & event.buttons();
    if (recipient.terminal != nullptr && held != Qt::NoButton) {
      deliver(*recipient.terminal, event, held);
    }
  }

  const auto *grabber = event.exclusiveGrabber(event.point(0));

  return grabber == nullptr || qobject_cast<const TerminalItem *>(grabber) != nullptr;
}

bool PointerDispatcher::release(QMouseEvent &event) {
  auto *lease = capture(event.button());
  if (lease == nullptr || !lease->held) {
    return false;
  }

  auto previous = std::exchange(*lease, Capture{});
  if (previous.child.owned()) {
    report(previous.pane_id, previous.child.deliver(view(previous), sample(event, MousePhase::release, mouseButton(event.button()))));
  } else if (previous.terminal != nullptr) {
    Qt::MouseButtons held;
    for (const auto &recipient : recipients()) {
      if (recipient.terminal == previous.terminal) {
        held = recipient.view_buttons & event.buttons();
      }
    }

    deliver(*previous.terminal, event, held);
  }

  const auto *grabber = qobject_cast<TerminalItem *>(event.exclusiveGrabber(event.point(0)));
  if (grabber != nullptr && event.buttons() == Qt::NoButton) {
    event.setExclusiveGrabber(event.point(0), nullptr);
  }

  return grabber != nullptr || event.exclusiveGrabber(event.point(0)) == nullptr;
}

bool PointerDispatcher::eventFilter(QObject *watched, QEvent *event) {
  if (delivering_ || watched != window_) {
    return false;
  }

  try {
    switch (event->type()) {
    case QEvent::Wheel:
      return application_.handleHistoryWheel(dynamic_cast<QWheelEvent &>(*event));
    case QEvent::MouseButtonPress:
    case QEvent::MouseButtonDblClick: {
      auto &mouse = dynamic_cast<QMouseEvent &>(*event);
      application_.observeActivityPointer(true, mouse.position());

      return press(mouse);
    }
    case QEvent::MouseMove:
      return move(dynamic_cast<QMouseEvent &>(*event));
    case QEvent::Leave:
      application_.attachments_.observePointer(std::nullopt);
      application_.observeActivityPointer(false);
      return false;
    case QEvent::MouseButtonRelease:
      return release(dynamic_cast<QMouseEvent &>(*event));
    default:
      return false;
    }
  } catch (const std::exception &error) {
    cancel();
    application_.fail(error);

    return true;
  }
}

}
