module telar.gui.ui.app.panes.terminal;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.input;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  ds::Option<CopyPoint> TerminalItem::cellAt(QPointF position) const noexcept {
    const auto* current = pane();
    if (current == nullptr || current->screen.columns() == 0 || current->screen.rows() == 0 || font_.cell.width() <= 0 || font_.cell.height() <= 0 || !std::isfinite(position.x()) || !std::isfinite(position.y())) {
      return ds::none;
    }

    const auto column = static_cast<std::uint16_t>(std::clamp(std::floor(position.x() / font_.cell.width()), 0.0, static_cast<double>(current->screen.columns() - 1)));
    const auto drawn = std::floor((position.y() + shift_) / font_.cell.height());

    // A view that draws its own rows knows which row each one is: folds and rows from beyond
    // the screen included.
    if (!view_rows_.empty()) {
      auto index = static_cast<std::size_t>(std::clamp(drawn, 0.0, static_cast<double>(view_rows_.size() - 1)));

      while (index > 0 && !view_rows_[index].exists) {
        --index;
      }

      if (!view_rows_[index].exists) {
        return ds::none;
      }

      return CopyPoint{.x = column, .y = static_cast<std::uint32_t>(std::min<std::uint64_t>(view_rows_[index].row, std::numeric_limits<std::uint32_t>::max()))};
    }

    // The screen's rows, from the row its cells start on: the view the runtime last sent, not
    // one asked for since.
    const auto row = static_cast<std::uint32_t>(std::clamp(drawn, 0.0, static_cast<double>(current->screen.rows() - 1)));

    return CopyPoint{.x = column, .y = current->screen.cellsOffset() + row};
  }

  CellSelection TerminalItem::drawnSelection(const application::terminal::copy_mode::CopyState& copy) const noexcept {
    const auto* current = pane();
    if (!copy.anchor || current == nullptr || current->screen.columns() == 0) {
      return {};
    }

    const auto columns = static_cast<std::size_t>(current->screen.columns());
    auto first = std::min(*copy.anchor, copy.cursor);
    auto last = std::max(*copy.anchor, copy.cursor);

    if (copy.linewise) {
      first.x = 0;
      last.x = static_cast<std::uint16_t>(columns - 1);
    }

    // The first drawn row at or past the selection's start, and the last at or before its end:
    // folds between them hide rows the copy still takes.
    ds::Option<std::size_t> head;
    ds::Option<std::size_t> tail;

    for (std::size_t index = 0; index < view_rows_.size(); ++index) {
      const auto& view = view_rows_[index];
      if (!view.exists || view.row < first.y || view.row > last.y) {
        continue;
      }

      if (!head) {
        head = (index * columns) + (view.row == first.y ? first.x : 0);
      }

      tail = (index * columns) + (view.row == last.y ? last.x : columns - 1);
    }

    if (!head || !tail) {
      return {};
    }

    return {.anchor = static_cast<int>(*head), .head = static_cast<int>(*tail)};
  }

  void TerminalItem::mousePacket(unsigned button, QPointF position, bool released) {
    const auto* current = pane();
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
    application::terminal::input::MouseEncoder encoder;
    const auto packet = encoder.encode(button, x, y, released, current->screen.mouse().sgr);

    send(QByteArray{packet.data(), static_cast<qsizetype>(packet.size())}, application::PaneInputSource::mouse);
  }

  unsigned TerminalItem::mouseModifiers(Qt::KeyboardModifiers modifiers) noexcept {
    unsigned result = modifiers.testFlag(Qt::ShiftModifier) ? mouse_shift : 0;

    result |= modifiers.testFlag(Qt::AltModifier) ? mouse_alt : 0;
    result |= modifiers.testFlag(NativeKeyAdapter::control_modifier) ? mouse_control : 0;

    return result;
  }

  application::terminal::input::ChildMouseView TerminalItem::childMouseView() const {
    const auto* current = pane();
    if (current == nullptr) {
      return {};
    }

    return {.pane_id = current->id, .location = current->location, .surface = terminalSurface(), .protocol = current->screen.mouse(), .columns = current->screen.columns(), .rows = current->screen.rows(), .cell_width_px = current->size.cell_width_px, .cell_height_px = current->size.cell_height_px, .attached = current->attached, .visible = isVisible() && window() != nullptr};
  }

  application::terminal::input::ChildMouseSample TerminalItem::childMouseSample(const QMouseEvent& event, application::terminal::input::MousePhase phase, application::terminal::input::MouseButton button) const {
    const auto position = mapToScene(event.position());

    return {.button = button, .phase = phase, .position = {.x = static_cast<float>(position.x()), .y = static_cast<float>(position.y())}, .modifiers = mouseModifiers(event.modifiers())};
  }

  application::terminal::copy_mode::CopyPointerInput TerminalItem::pointerInput(QPointF position, application::terminal::copy_mode::CopyPointerKind kind, bool left_button, std::int32_t rows) const noexcept {
    application::terminal::copy_mode::CopyPointerInput input{.pane_id = pane_id_, .kind = kind, .left_button = left_button, .inside = boundingRect().contains(position), .rows = rows};
    const auto cell = cellAt(position);
    if (!cell) {
      input.pane_id = 0;

      return input;
    }

    input.position = *cell;

    return input;
  }

  void TerminalItem::mousePressEvent(QMouseEvent* event) {
    const auto* current = pane();
    if (current == nullptr || controller_ == nullptr) {
      return;
    }

    controller_->acquire(*this, event->button());
    const auto left = event->button() == Qt::LeftButton;
    const auto input = pointerInput(event->position(), application::terminal::copy_mode::CopyPointerKind::press, left);
    if (controller_->copy().handlePointer(input)) {
      event->accept();

      return;
    }

    if (!visibleCellAt(event->position()) || link_hover_.covers({.x = static_cast<float>(event->position().x()), .y = static_cast<float>(event->position().y())}) || !link_hover_.surfaceVisible(terminalSurface())) {
      captured_link_buttons_.setFlag(event->button());
      link_gesture_.cancel();
      event->accept();

      return;
    }

    controller_->host().focusPane(*this);
    forceActiveFocus(Qt::MouseFocusReason);
    selection_position_ = event->position();
    if (beginLinkPress(*event)) {
      event->accept();

      return;
    }

    const auto child_tracking = current->screen.mouse().tracking != MouseTracking::none && !(left && event->modifiers().testFlag(Qt::ShiftModifier));
    const auto button = mouseButton(event->button());
    if (child_tracking && button != application::terminal::input::MouseButton::none) {
      const auto view = childMouseView();
      const auto sample = childMouseSample(*event, application::terminal::input::MousePhase::press, button);

      controller_->beginChild(view, sample);
    } else if (left && input.pane_id != 0 && input.inside) {
      selecting_ = controller_->copy().beginSelection(pane_id_, input.position);
    } else if (event->button() == Qt::MiddleButton && QGuiApplication::clipboard()->supportsSelection()) {
      controller_->paste(pane_id_, QGuiApplication::clipboard()->text(QClipboard::Selection));
    }

    event->accept();
  }

  void TerminalItem::mouseDoubleClickEvent(QMouseEvent* event) {
    mousePressEvent(event);
  }

  void TerminalItem::mouseMoveEvent(QMouseEvent* event) {
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

    const auto input = pointerInput(event->position(), application::terminal::copy_mode::CopyPointerKind::drag, event->buttons().testFlag(Qt::LeftButton));
    if (controller_ != nullptr && controller_->copy().handlePointer(input)) {
      event->accept();

      return;
    }

    event->accept();
  }

  void TerminalItem::mouseReleaseEvent(QMouseEvent* event) {
    const auto release = qScopeGuard([this, button = event->button()] {
      if (controller_ != nullptr) {
        controller_->release(button);
      }
    });

    if (captured_link_buttons_.testFlag(event->button())) {
      captured_link_buttons_.setFlag(event->button(), false);
      finishLinkRelease(*event);
      event->accept();

      return;
    }

    const auto left = event->button() == Qt::LeftButton;
    const auto input = pointerInput(event->position(), application::terminal::copy_mode::CopyPointerKind::release, left);
    const auto copied = controller_ != nullptr && controller_->copy().handlePointer(input);

    if (left) {
      selecting_ = false;
    }

    static_cast<void>(copied);
    finishLinkRelease(*event);
    event->accept();
  }

  void TerminalItem::mouseUngrabEvent() {
    if (controller_ != nullptr) {
      controller_->host().ungrabPointer(*this);
    } else {
      releaseMouse();
    }
  }

  void TerminalItem::releaseMouse() {
    if (controller_ != nullptr) {
      controller_->abandon(*this);
    }

    const auto selecting = std::exchange(selecting_, false);
    if (selecting && controller_ != nullptr) {
      static_cast<void>(controller_->copy().handlePointer(pointerInput(selection_position_, application::terminal::copy_mode::CopyPointerKind::release)));
    }

    link_gesture_.cancel();
    captured_link_buttons_ = {};
  }

  void TerminalItem::resetWheel() noexcept {
    wheel_.reset();
  }

  void TerminalItem::wheelEvent(QWheelEvent* event) {
    const auto* current = pane();
    if (current == nullptr || controller_ == nullptr) {
      return;
    }

    if (controller_->dialog() != Store::Dialog::none || link_hover_.covers({.x = static_cast<float>(event->position().x()), .y = static_cast<float>(event->position().y())}) || !link_hover_.surfaceVisible(terminalSurface())) {
      wheel_.reset();
      event->accept();

      return;
    }

    controller_->observeScroll(*this);
    if (scrollWheel(*event)) {
      event->accept();

      return;
    }

    const auto lines = wheel_.consume(scrollSample(*event, font_.cell.height()));
    const auto rows = lines * WheelAccumulator::rows_per_line;
    if (lines != 0 && !controller_->copy().handlePointer(pointerInput(event->position(), application::terminal::copy_mode::CopyPointerKind::wheel, true, rows))) {
      dispatchWheel(*event, lines);
    }

    event->accept();
  }

  void TerminalItem::dispatchWheel(const QWheelEvent& event, std::int32_t lines) {
    const auto* current = pane();
    if (current == nullptr || controller_ == nullptr) {
      return;
    }

    const auto rows = lines * WheelAccumulator::rows_per_line;

    switch (wheelRoute(current->screen)) {
    case WheelRoute::report: {
      const auto modifiers = mouseModifiers(event.modifiers());

      for (int step = 0; step < std::abs(lines); ++step) {
        mousePacket((lines < 0 ? application::terminal::input::MouseEncoder::wheel_up : application::terminal::input::MouseEncoder::wheel_down) | modifiers, event.position(), false);
      }

      return;
    }
    case WheelRoute::keys: {
      KeyEncoder encoder;
      const auto bytes = encoder.alternateScroll(rows < 0, current->screen.modes());

      for (int step = 0; step < std::abs(rows); ++step) {
        send(QByteArray{bytes.data(), static_cast<qsizetype>(bytes.size())});
      }

      return;
    }
    case WheelRoute::scroll: {
      // Rows down that reach where the live end was follow the output again.
      const auto& scroll = current->screen.scroll();
      const auto bottom = static_cast<std::uint64_t>(scroll.total_rows - std::min<std::uint32_t>(scroll.total_rows, current->screen.rows()));
      const auto left_end = bottom - std::min(bottom, rowsSinceLeftEnd());
      if (rows > 0 && static_cast<std::uint64_t>(scroll.offset) + static_cast<std::uint64_t>(rows) >= left_end) {
        scrollToEnd();
      } else {
        controller_->scroll({.pane_id = pane_id_, .rows = -rows});
      }

      return;
    }
    }
  }

  void TerminalItem::hoverMoveEvent(QHoverEvent* event) {
    const auto* current = pane();

    if (controller_ != nullptr && controller_->copy().handlePointer(pointerInput(event->position(), application::terminal::copy_mode::CopyPointerKind::move, false))) {
      setCursor(Qt::IBeamCursor);
      event->accept();

      return;
    }

    if (controller_ != nullptr && current != nullptr && current->screen.mouse().sgr && current->screen.mouse().tracking == MouseTracking::any && visibleCellAt(event->position()) && controller_->dialog() == Store::Dialog::none && !link_hover_.covers({.x = static_cast<float>(event->position().x()), .y = static_cast<float>(event->position().y())})) {
      const auto no_button = static_cast<unsigned>(application::terminal::input::MouseButton::none);

      mousePacket(application::terminal::input::ChildMouseProjection::motion | no_button | mouseModifiers(event->modifiers()), event->position(), false);
    }

    observeLinkPointer(event->position(), event->modifiers());
    event->accept();
  }
}
