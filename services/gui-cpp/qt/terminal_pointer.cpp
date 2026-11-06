#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include <cmath>
#include "telar_client/serializers/telar_frame.hpp"
#include "../terminal/cell_position.hpp"
#include <charconv>
#include "../input/wheel_accumulator.hpp"
#include "key_adapter.hpp"
#include "mouse_buttons.hpp"
#include "pointer_dispatcher.hpp"
#include "scroll_event.hpp"
#include "terminal_item.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QHoverEvent>
#include <QMouseEvent>
#include <QPointF>
#include <QScopeGuard>
#include <QWheelEvent>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>

#include "input/wheel_accumulator.hpp"
#include "terminal/screen.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.input.child_mouse;
import telar.gui.input.copy_pointer;
import telar.gui.input.configuration;
import telar.gui.terminal.font_grid;

namespace telar::gui::qt {

namespace {

using Action = Application::Action;

}

int TerminalItem::indexAt(QPointF position) const noexcept {
  const auto *current = pane();
  if (current == nullptr || current->screen.columns() == 0 || current->screen.rows() == 0 || font_.cell.width() <= 0 || font_.cell.height() <= 0 || !std::isfinite(position.x()) || !std::isfinite(position.y())) {
    return -1;
  }

  const auto column = static_cast<int>(std::clamp(std::floor(position.x() / font_.cell.width()), 0.0, static_cast<double>(current->screen.columns() - 1)));
  const auto row = static_cast<int>(std::clamp(std::floor(position.y() / font_.cell.height()), 0.0, static_cast<double>(current->screen.rows() - 1)));

  return (row * current->screen.columns()) + column;
}

void TerminalItem::mousePacket(unsigned button, QPointF position, bool released) {
  const auto *current = pane();
  if (current == nullptr) {
    return;
  }

  const auto scale = current->screen.mouse().pixels && window() != nullptr ? window()->effectiveDevicePixelRatio() : 1;
  const auto columns = static_cast<unsigned>(current->screen.columns());
  const auto rows = static_cast<unsigned>(current->screen.rows());
  const auto maximum_x = std::max(1U, columns * (current->screen.mouse().pixels ? current->size.cell_width_px : 1U));
  const auto maximum_y = std::max(1U, rows * (current->screen.mouse().pixels ? current->size.cell_height_px : 1U));
  const auto x = static_cast<unsigned>(std::clamp(position.x() * scale / (current->screen.mouse().pixels ? 1 : font_.cell.width()), 0.0, static_cast<double>(maximum_x - 1))) + 1;
  const auto y = static_cast<unsigned>(std::clamp(position.y() * scale / (current->screen.mouse().pixels ? 1 : font_.cell.height()), 0.0, static_cast<double>(maximum_y - 1))) + 1;
  MouseEncoder encoder;
  const auto packet = encoder.encode(button, x, y, released, current->screen.mouse().sgr);
  send(QByteArray{packet.data(), static_cast<qsizetype>(packet.size())}, PaneInputSource::mouse);
}

unsigned TerminalItem::mouseModifiers(Qt::KeyboardModifiers modifiers) noexcept {
  unsigned result = modifiers.testFlag(Qt::ShiftModifier) ? mouse_shift : 0;
  result |= modifiers.testFlag(Qt::AltModifier) ? mouse_alt : 0;
  result |= modifiers.testFlag(NativeKeyAdapter::control_modifier) ? mouse_control : 0;

  return result;
}

ChildMouseView TerminalItem::childMouseView() const {
  const auto *current = pane();
  if (current == nullptr) {
    return {};
  }

  return {.pane_id = current->id, .location = current->location, .surface = terminalSurface(), .protocol = current->screen.mouse(), .columns = current->screen.columns(), .rows = current->screen.rows(), .cell_width_px = current->size.cell_width_px, .cell_height_px = current->size.cell_height_px, .attached = current->attached, .visible = isVisible() && window() != nullptr};
}

ChildMouseSample TerminalItem::childMouseSample(const QMouseEvent &event, MousePhase phase, MouseButton button) const {
  const auto position = mapToScene(event.position());

  return {.button = button, .phase = phase, .position = {.x = static_cast<float>(position.x()), .y = static_cast<float>(position.y())}, .modifiers = mouseModifiers(event.modifiers())};
}

CopyPointerInput TerminalItem::pointerInput(QPointF position, CopyPointerKind kind, bool left_button, std::int32_t rows) const noexcept {
  CopyPointerInput input{.pane_id = pane_id_, .kind = kind, .left_button = left_button, .inside = boundingRect().contains(position), .rows = rows};
  const auto index = indexAt(position);
  const auto *current = pane();
  if (index < 0 || current == nullptr) {
    input.pane_id = 0;

    return input;
  }

  const auto columns = current->screen.columns();
  input.position = {.x = static_cast<std::uint16_t>(index % columns), .y = static_cast<std::uint32_t>(index / columns)};

  return input;
}

void TerminalItem::mousePressEvent(QMouseEvent *event) {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr) {
    return;
  }

  application_->pointerDispatcher().acquire(*this, event->button());
  const auto left = event->button() == Qt::LeftButton;
  const auto input = pointerInput(event->position(), CopyPointerKind::press, left);
  if (application_->handleCopyPointer(input)) {
    event->accept();

    return;
  }

  if (!visibleCellAt(event->position()) || link_hover_.covers({.x = static_cast<float>(event->position().x()), .y = static_cast<float>(event->position().y())}) || !link_hover_.surfaceVisible(terminalSurface())) {
    captured_link_buttons_.setFlag(event->button());
    link_gesture_.cancel();
    event->accept();

    return;
  }

  application_->execute(Action::focus_pane, paneId());
  forceActiveFocus(Qt::MouseFocusReason);
  selection_position_ = event->position();
  if (beginLinkPress(*event)) {
    event->accept();

    return;
  }

  const auto child_tracking = current->screen.mouse().tracking != MouseTracking::none && !(left && event->modifiers().testFlag(Qt::ShiftModifier));
  const auto button = mouseButton(event->button());
  if (child_tracking && button != MouseButton::none) {
    const auto view = childMouseView();
    const auto sample = childMouseSample(*event, MousePhase::press, button);
    application_->pointerDispatcher().beginChild(view, sample);
  } else if (left && input.pane_id != 0 && input.inside) {
    selecting_ = application_->beginSelection(pane_id_, input.position);
  } else if (event->button() == Qt::MiddleButton && QGuiApplication::clipboard()->supportsSelection()) {
    application_->paste(pane_id_, QGuiApplication::clipboard()->text(QClipboard::Selection));
  }

  event->accept();
}

void TerminalItem::mouseDoubleClickEvent(QMouseEvent *event) {
  mousePressEvent(event);
}

void TerminalItem::mouseMoveEvent(QMouseEvent *event) {
  if (event->buttons().testFlag(Qt::LeftButton) || selecting_ || captured_link_buttons_.testFlag(Qt::LeftButton)) {
    link_gesture_.cancel();
  }

  observeLinkPointer(event->position(), event->modifiers());
  if (captured_link_buttons_.testFlag(Qt::LeftButton)) {
    event->accept();

    return;
  }

  if (selecting_) {
    selection_position_ = event->position();
  }

  const auto input = pointerInput(event->position(), CopyPointerKind::drag, event->buttons().testFlag(Qt::LeftButton));
  if (application_ != nullptr && application_->handleCopyPointer(input)) {
    event->accept();

    return;
  }

  event->accept();
}

void TerminalItem::mouseReleaseEvent(QMouseEvent *event) {
  const auto release = qScopeGuard([this, button = event->button()] {
    if (application_ != nullptr) {
      application_->pointerDispatcher().release(button);
    }
  });
  if (captured_link_buttons_.testFlag(event->button())) {
    captured_link_buttons_.setFlag(event->button(), false);
    finishLinkRelease(*event);
    event->accept();

    return;
  }

  const auto left = event->button() == Qt::LeftButton;
  const auto input = pointerInput(event->position(), CopyPointerKind::release, left);
  const auto copied = application_ != nullptr && application_->handleCopyPointer(input);
  if (left) {
    selecting_ = false;
  }

  static_cast<void>(copied);
  finishLinkRelease(*event);
  event->accept();
}

void TerminalItem::mouseUngrabEvent() {
  if (application_ != nullptr) {
    application_->pointerDispatcher().ungrab(*this);
  } else {
    releaseMouse();
  }
}

void TerminalItem::releaseMouse() {
  if (application_ != nullptr) {
    application_->pointerDispatcher().abandon(*this);
  }

  const auto selecting = std::exchange(selecting_, false);
  if (selecting && application_ != nullptr) {
    static_cast<void>(application_->handleCopyPointer(pointerInput(selection_position_, CopyPointerKind::release)));
  }

  link_gesture_.cancel();
  captured_link_buttons_ = {};
}

void TerminalItem::wheelEvent(QWheelEvent *event) {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr) {
    return;
  }

  if (!application_->dialog().isEmpty() || link_hover_.covers({.x = static_cast<float>(event->position().x()), .y = static_cast<float>(event->position().y())}) || !link_hover_.surfaceVisible(terminalSurface())) {
    wheel_.reset();
    event->accept();

    return;
  }

  application_->pointerDispatcher().observeTerminalScroll(*this);
  const auto lines = wheel_.consume(scrollSample(*event, font_.cell.height()));
  const auto rows = lines * WheelAccumulator::rows_per_line;
  if (lines != 0 && !application_->handleCopyPointer(pointerInput(event->position(), CopyPointerKind::wheel, true, rows))) {
    dispatchWheel(*event, lines);
  }

  event->accept();
}

void TerminalItem::dispatchWheel(const QWheelEvent &event, std::int32_t lines) {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr) {
    return;
  }

  const auto rows = lines * WheelAccumulator::rows_per_line;
  if (current->screen.mouse().sgr && (current->screen.mouse().tracking == MouseTracking::normal || current->screen.mouse().tracking == MouseTracking::button || current->screen.mouse().tracking == MouseTracking::any)) {
    const auto modifiers = mouseModifiers(event.modifiers());
    for (int step = 0; step < std::abs(lines); ++step) {
      mousePacket((lines < 0 ? MouseEncoder::wheel_up : MouseEncoder::wheel_down) | modifiers, event.position(), false);
    }
  } else if (current->screen.modes().alternate_screen && current->screen.modes().alternate_scroll && current->screen.scroll().offset == copyGrid(current->screen).maximumOffset()) {
    for (int step = 0; step < std::abs(rows); ++step) {
      send(rows < 0 ? "\x1b[A" : "\x1b[B");
    }
  } else {
    application_->scroll({.pane_id = pane_id_, .rows = -rows});
  }
}

void TerminalItem::hoverMoveEvent(QHoverEvent *event) {
  const auto *current = pane();
  if (application_ != nullptr && application_->handleCopyPointer(pointerInput(event->position(), CopyPointerKind::move, false))) {
    setCursor(Qt::IBeamCursor);
    event->accept();

    return;
  }

  if (application_ != nullptr && current != nullptr && current->screen.mouse().sgr && current->screen.mouse().tracking == MouseTracking::any && visibleCellAt(event->position()) && application_->dialog().isEmpty() && !link_hover_.covers({.x = static_cast<float>(event->position().x()), .y = static_cast<float>(event->position().y())})) {
    const auto no_button = static_cast<unsigned>(MouseButton::none);
    mousePacket(ChildMouseProjection::motion | no_button | mouseModifiers(event->modifiers()), event->position(), false);
  }

  observeLinkPointer(event->position(), event->modifiers());
  event->accept();
}
}
