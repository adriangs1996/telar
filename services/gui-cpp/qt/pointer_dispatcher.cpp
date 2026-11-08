#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <array>
#include <string_view>
#include <optional>
#include <utility>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <span>
#include <variant>
#include <QString>
#include "pointer_dispatcher.hpp"
#include "application.hpp"
#include "../platform/scroll_event.hpp"
#include <QCoreApplication>
#include "attachment_shelf.hpp"
#include "native_pointer_events.hpp"
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "../terminal/cell_position.hpp"
#include "mouse_buttons.hpp"
#include "terminal_item.hpp"
#include <QMouseEvent>
#include <QKeyEvent>
#include <QQuickWindow>
#include <QScopedValueRollback>
#include <QWindow>
#include <QWheelEvent>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qobject.h>
#include <QtCore/qtypes.h>
#include <QtCore/qstringliteral.h>

#include "platform/scroll_event.hpp"


import telar.gui.input.child_mouse;
import telar.gui.history.browser;
import telar.gui.application.workspace_replica;
import telar.gui.input.configuration;
import telar.gui.links.link_hover;

namespace telar::gui::qt {

PointerDispatcher::PointerDispatcher(Application &application)
    : QObject(&application),
      application_(application),
      native_events_(application.memory_),
      history_scroll_events_(*this) {
  connect(&application, &Application::inputReleasing, this, &PointerDispatcher::cancelPane);
}

void PointerDispatcher::setWindow(QQuickWindow &window) {
  if (window_ != nullptr) {
    cancel();
    window_->removeEventFilter(this);
    window_->disconnect(this);
  }

  window_ = &window;
  history_scroll_events_.setActive(true);

  application_.observeActivityPointer(false);
  window.installEventFilter(this);
  connect(&window, &QWindow::activeChanged, this, [this] {
    if (window_ != nullptr && !window_->isActive()) {
      application_.observeActivityPointer(false);
      cancel();
    }
  });
}

// Cocoa's native phase keeps fractional scroll across momentum and distinguishes
// cancellation before Qt merges those phases into its wheel-event stream.
bool PointerDispatcher::handleNativeScroll(std::string_view event_type, const void *message) {
  if (window_.isNull() || application_.dialog_ != QStringView{u"history"}) {
    return false;
  }

  const auto input = platform::nativeScrollInput(event_type, message, *window_);
  if (!input) {
    return false;
  }

  if (input->valid) {
    application_.scrollHistory({.x = input->x, .y = input->y}, input->sample);
  }

  return true;
}

void PointerDispatcher::observeTerminalScroll(TerminalItem &terminal) {
  if (terminal_scroll_owner_ != &terminal) {
    retireTerminalScroll();
    terminal_scroll_owner_ = &terminal;
  }
}

void PointerDispatcher::retireTerminalScroll() {
  if (!terminal_scroll_owner_.isNull() && terminal_scroll_owner_->application() == &application_ && terminal_scroll_owner_->window() == window_) {
    terminal_scroll_owner_->wheel_.reset();
  }

  terminal_scroll_owner_.clear();
}

PointerDispatcher::Capture *PointerDispatcher::capture(Qt::MouseButton button) noexcept {
  const auto semantic = mouseButton(button);

  return semantic == MouseButton::none ? nullptr : &captures_[static_cast<std::size_t>(semantic)];
}

bool PointerDispatcher::occupied() const noexcept {
  return std::ranges::any_of(captures_, &Capture::held);
}

void PointerDispatcher::notifyHistoryHover() {
  const auto &identity = history_hover_.hovered();
  const auto *row = identity ? std::get_if<HistoryChoice>(&identity->action) : nullptr;
  if (const auto *footer = identity ? std::get_if<HistoryFooterIdentity>(&identity->action) : nullptr; footer != nullptr && footer->submission()) {
    row = &footer->choice;
  }

  if (const auto *inspection = identity ? std::get_if<HistoryInspectionIdentity>(&identity->action) : nullptr; inspection != nullptr && inspection->submission()) {
    row = &inspection->choice;
  }

  if (row != nullptr && history_hover_revision_value_ != row->revision) {
    history_hover_revision_value_ = row->revision;
    history_hover_revision_ = QString::number(row->revision);
  }

  emit application_.historyHoverChanged();
}

void PointerDispatcher::retireHistoryHover() {
  if (history_hover_.cancel()) {
    notifyHistoryHover();
  }
}

void PointerDispatcher::presentHistoryHover(std::span<const HistoryHoverTarget> targets) {
  if (history_hover_.present(targets)) {
    notifyHistoryHover();
  }
}

void PointerDispatcher::observeHistoryHover(QPointF position, HistoryHover::Observation observation) {
  const auto &frame = application_.presented_history_hover_;
  if (application_.dialog_ != QStringLiteral("history") || !frame || frame->generation != application_.dialog_generation_) {
    retireHistoryHover();

    return;
  }

  if (history_hover_.observe(frame->view(), {.x = position.x() * frame->scale, .y = position.y() * frame->scale}, observation)) {
    notifyHistoryHover();
  }
}

void PointerDispatcher::acquire(TerminalItem &terminal, Qt::MouseButton button) {
  if (auto *lease = capture(button)) {
    *lease = {.terminal = &terminal, .history = {}, .pane_id = terminal.paneIdentity(), .held = true};
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

void PointerDispatcher::presentHistoryActions(const HistoryActionSurface &surface) {
  for (auto &lease : captures_) {
    if (lease.history.held()) {
      lease.history.present(surface);
    }
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
  observeTabHover(std::nullopt);
  cancelTabDrag();
  retireHistoryHover();
  const auto previous_recipients = recipients();
  for (std::size_t index = 0; index < captures_.size(); ++index) {
    auto &lease = captures_[index];
    lease.history.cancel();
    const auto pane_id = lease.pane_id;
    const auto outcome = lease.child.owned() ? std::optional{lease.child.cancel(view(lease))} : std::nullopt;
    lease.terminal.clear();
    if (outcome) {
      report(pane_id, *outcome);
    }
  }

  for (const auto &recipient : previous_recipients) {
    if (auto *const terminal = recipient.terminal.data(); terminal != nullptr) {
      terminal->releaseMouse();
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
  if (pressTab(event)) {
    return false;
  }

  observeHistoryHover(event.position(), HistoryHover::Observation::point);
  if (auto *lease = capture(event.button())) {
    if (lease->history.held()) {
      *lease = {};
    }

    const auto &surface = application_.presented_history_actions_;
    HistoryActionCapture history;
    if (application_.dialog_ == QStringLiteral("history") && surface.generation == application_.dialog_generation_ && history.begin(surface, {.x = event.position().x() * surface.scale, .y = event.position().y() * surface.scale}, event.button() == Qt::LeftButton)) {
      *lease = {.terminal = {}, .history = history, .held = true};

      return true;
    }
  }

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
    observeHistoryHover(event.position(), event.buttons() == Qt::NoButton ? HistoryHover::Observation::point : HistoryHover::Observation::retained);
  }

  application_.observeActivityPointer(true, event.position());
  const auto tab_consumed = updateTabDrag(event, false);

  if (!occupied()) {
    return tab_consumed;
  }

  const auto destinations = recipients();
  for (const auto &destination : destinations) {
    auto *const terminal = destination.terminal.data();
    if (terminal != nullptr && (destination.child_buttons & event.buttons()) != Qt::NoButton) {
      terminal->observeLinkPointer(terminal->mapFromScene(event.position()), event.modifiers());
      if (destination.child_buttons.testFlag(Qt::LeftButton)) {
        terminal->link_gesture_.cancel();
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

  return tab_consumed || grabber == nullptr || qobject_cast<const TerminalItem *>(grabber) != nullptr;
}

bool PointerDispatcher::release(QMouseEvent &event) {
  if (event.button() == Qt::LeftButton && updateTabDrag(event, true)) {
    return true;
  }

  auto *lease = capture(event.button());
  if (lease == nullptr || !lease->held) {
    return false;
  }

  auto previous = std::exchange(*lease, Capture{});
  if (previous.history.held()) {
    const auto &surface = application_.presented_history_actions_;
    const auto action = previous.history.release(surface, {.x = event.position().x() * surface.scale, .y = event.position().y() * surface.scale});
    const auto choice = surface.choice;
    if (application_.dialog_ != QStringLiteral("history") || surface.generation != application_.dialog_generation_) {
      return true;
    }

    if (action && choice) {
      application_.activateHistoryCardAction(*action, *choice);
    }

    return true;
  }

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
      observeTabHover(mouse.position());

      return press(mouse);
    }
    case QEvent::MouseMove: {
      auto &mouse = dynamic_cast<QMouseEvent &>(*event);
      observeTabHover(mouse.position());
      return move(mouse);
    }
    case QEvent::ShortcutOverride:
    case QEvent::KeyPress:
    case QEvent::KeyRelease: {
      return tabKey(dynamic_cast<QKeyEvent &>(*event));
    }
    case QEvent::Leave:
      observeTabHover(std::nullopt);
      if (tab_drag_.captured()) {
        const auto scale = tab_capture_surface_.scale / tab_capture_surface_.threshold;
        tab_drag_.update({tab_pointer_.x() * scale, tab_pointer_.y() * scale}, std::nullopt);
        updateTabDragVisual();
      }
      retireHistoryHover();
      application_.attachments_.observePointer(std::nullopt);
      application_.observeActivityPointer(false);
      return false;
    case QEvent::MouseButtonRelease: {
      auto &mouse = dynamic_cast<QMouseEvent &>(*event);
      observeTabHover(mouse.position());
      return release(mouse);
    }
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
