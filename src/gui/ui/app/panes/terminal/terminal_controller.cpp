#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "terminal_controller.hpp"
#include "telar_base/memory/allocator.hpp"
#include "terminal_item.hpp"
#include "ui/app/panes/terminal/scene/window_images.hpp"
#include <QCoreApplication>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <exception>
#include <utility>

import telar.gui.application;
import telar.gui.foundation.model;

namespace telar::gui::qt {

  TerminalController::TerminalController(Store& store, CopyController& copy, PromptController& prompt, TerminalHost& host, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        copy_(copy),
        prompt_(prompt),
        host_(host),
        memory_(memory) {}

  ViewVersion TerminalController::viewVersion() const noexcept {
    auto version = store_.session().viewVersion();

    version.machine = store_.machineView();

    return version;
  }

  void TerminalController::setWindow(QQuickWindow& window) {
    QObject::disconnect(placements_connection_);
    window_ = &window;
    WindowImages::forWindow(window);
    placements_connection_ = connect(&window, &QQuickWindow::afterAnimating, this, &TerminalController::prepareImagePlacements);
  }

  void TerminalController::setChromeRatio(qreal ratio) noexcept {
    chrome_ratio_ = ratio;
  }

  void TerminalController::registerTerminal(TerminalItem& terminal) {
    if (terminal.paneIdentity() != 0) {
      terminals_.insert(terminal.paneIdentity(), &terminal);
    }
  }

  void TerminalController::unregisterTerminal(TerminalItem& terminal) {
    const auto found = terminals_.find(terminal.paneIdentity());
    if (found != terminals_.end() && *found == &terminal) {
      terminals_.erase(found);
    }
  }

  TerminalItem* TerminalController::terminal(std::uint64_t pane_id) const {
    return terminals_.value(pane_id);
  }

  TerminalItem* TerminalController::visible(std::uint64_t pane_id) const {
    const auto terminal = terminals_.constFind(pane_id);
    if (terminal == terminals_.cend() || *terminal == nullptr || (*terminal)->window() != window_ || !(*terminal)->isVisible() || !(*terminal)->flags().testFlag(QQuickItem::ItemHasContents) || (*terminal)->width() <= 0 || (*terminal)->height() <= 0) {
      return nullptr;
    }

    return *terminal;
  }

  bool TerminalController::input(std::uint64_t pane_id, const QByteArray& bytes, application::PaneInputSource source) {
    auto& session = store_.session();
    const auto* const current = session.findPane(pane_id);
    if (current == nullptr || !current->attached || current->exited || bytes.isEmpty()) {
      return false;
    }

    const auto& copy = application::terminal::copy_mode::view(session).state();
    const auto previous = copy && copy->pointer ? copy->pane_id : 0;
    bool delivered = false;

    try {
      session.input(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())}, source);
      delivered = true;
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    if (previous != 0 && !application::terminal::copy_mode::view(session).state()) {
      copy_.publishChange(previous);
    }

    return delivered;
  }

  void TerminalController::paste(std::uint64_t pane_id, const QString& text) {
    try {
      const auto bytes = text.toUtf8();

      store_.session().paste(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    prompt_.publishWrite();
  }

  void TerminalController::resize(std::uint64_t pane_id, TerminalSize size) {
    try {
      store_.session().resize(pane_id, size);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void TerminalController::scroll(application::PaneScrollDelta delta) {
    try {
      store_.session().scroll(delta);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void TerminalController::scrollToRow(std::uint64_t pane_id, std::uint32_t row) {
    try {
      store_.session().scrollToRow(pane_id, row);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void TerminalController::selectBlock(std::uint64_t pane_id, std::optional<std::size_t> index) {
    try {
      store_.session().selectBlock(pane_id, index);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    prompt_.publish(pane_id);
    emit terminalChanged(pane_id);
  }

  void TerminalController::observePointerModifiers(Qt::KeyboardModifiers modifiers) {
    if (pointer_modifiers_ != modifiers) {
      pointer_modifiers_ = modifiers;
      emit pointerModifiersChanged();
    }
  }

  std::shared_ptr<const application::terminal::links::LinkHit> TerminalController::shareLinkHit(const application::terminal::links::LinkHit& hit) {
    return std::allocate_shared<application::terminal::links::LinkHit>(AllocatorRef<application::terminal::links::LinkHit, ApplicationAllocator>{memory_}, hit);
  }

  void TerminalController::prepareImagePlacements() {
    if (window_ == nullptr) {
      return;
    }

    auto& session = store_.session();
    std::array<ImagePlacementSource, PaneLayout::maximum_panes> sources;
    std::size_t count = 0;
    const auto* tab = session.activeTab();
    if (tab != nullptr) {
      forEachLeaf(*tab, true, [&](const ClientLayoutPane& leaf) {
        const auto* pane = session.findPane(leaf.pane_id);
        const auto terminal = terminals_.constFind(leaf.pane_id);
        if (pane != nullptr && pane->attached && terminal != terminals_.cend() && *terminal != nullptr && (*terminal)->window() == window_ && (*terminal)->isVisible()) {
          sources[count++] = {.owner = *terminal, .store = &pane->graphics, .cell = (*terminal)->cellSize()};
        }
      });
    }

    if (const auto reach = WindowImages::forWindow(*window_).preparePlacements(std::span{sources}.first(count))) {
      application::notifications::reportLimit(session, *reach);
      emit notificationPublished();
    }
  }

  void TerminalController::releaseInput(std::uint64_t pane_id) {
    cancelPane(pane_id);
    emit inputReleasing(pane_id);
  }

  TerminalController::Capture* TerminalController::capture(Qt::MouseButton button) noexcept {
    const auto semantic = mouseButton(button);

    return semantic == application::terminal::input::MouseButton::none ? nullptr : &captures_[static_cast<std::size_t>(semantic)];
  }

  void TerminalController::acquire(TerminalItem& terminal, Qt::MouseButton button) {
    if (auto* lease = capture(button)) {
      *lease = {.terminal = &terminal, .pane_id = terminal.paneIdentity(), .held = true};
    }
  }

  void TerminalController::beginChild(const application::terminal::input::ChildMouseView& view, application::terminal::input::ChildMouseSample sample) {
    if (sample.button == application::terminal::input::MouseButton::none) {
      return;
    }

    auto& lease = captures_[static_cast<std::size_t>(sample.button)];

    lease.child.begin(view, sample);
    report(lease.pane_id, application::terminal::input::ChildMouseProjection::project(view, sample));
  }

  void TerminalController::release(Qt::MouseButton button) {
    if (auto* lease = capture(button)) {
      *lease = {};
    }
  }

  void TerminalController::abandon(TerminalItem& terminal) {
    for (auto& lease : captures_) {
      if (lease.terminal == &terminal) {
        lease.terminal.clear();
      }
    }
  }

  bool TerminalController::holdsPointer() const noexcept {
    return std::ranges::any_of(captures_, &Capture::held);
  }

  application::terminal::input::ChildMouseView TerminalController::view(const Capture& lease) const {
    if (const auto terminal = terminals_.value(lease.pane_id); terminal != nullptr) {
      return terminal->childMouseView();
    }

    const auto* current = pane(lease.pane_id);
    if (current == nullptr) {
      return {};
    }

    application::terminal::input::ChildMouseView result{.pane_id = current->id, .location = current->location, .protocol = current->screen.mouse(), .columns = current->screen.columns(), .rows = current->screen.rows(), .cell_width_px = current->size.cell_width_px, .cell_height_px = current->size.cell_height_px, .attached = current->attached, .visible = false};

    result.surface.attachment_generation = current->attachment_generation;

    return result;
  }

  application::terminal::input::ChildMouseSample TerminalController::sample(const QMouseEvent& event, application::terminal::input::MousePhase phase, application::terminal::input::MouseButton button) {
    return {.button = button, .phase = phase, .position = {.x = static_cast<float>(event.position().x()), .y = static_cast<float>(event.position().y())}, .modifiers = TerminalItem::mouseModifiers(event.modifiers())};
  }

  void TerminalController::report(std::uint64_t pane_id, const std::optional<application::terminal::input::ChildMouseReport>& report) {
    if (!report) {
      return;
    }

    application::terminal::input::MouseEncoder encoder;
    const auto packet = encoder.encode(report->button, report->x, report->y, report->released, true);

    input(pane_id, QByteArray{packet.data(), static_cast<qsizetype>(packet.size())}, application::PaneInputSource::mouse);
  }

  void TerminalController::cancelPane(std::uint64_t pane_id) {
    for (auto& lease : captures_) {
      if (lease.pane_id == pane_id) {
        if (lease.child.owned()) {
          report(pane_id, lease.child.cancel(view(lease)));
        }

        lease.terminal.clear();
      }
    }
  }

  void TerminalController::cancelPointer() {
    const auto previous_recipients = recipients();

    for (auto& lease : captures_) {
      const auto pane_id = lease.pane_id;
      const auto outcome = lease.child.owned() ? std::optional{lease.child.cancel(view(lease))} : std::nullopt;

      lease.terminal.clear();
      if (outcome) {
        report(pane_id, *outcome);
      }
    }

    for (const auto& recipient : previous_recipients) {
      if (auto* const terminal = recipient.terminal.data(); terminal != nullptr) {
        terminal->releaseMouse();
      }
    }
  }

  TerminalController::Recipients TerminalController::recipients() const {
    Recipients result;

    for (const auto& [native, semantic] : mouse_buttons) {
      const auto& lease = captures_[static_cast<std::size_t>(semantic)];
      if (!lease.held || lease.terminal == nullptr) {
        continue;
      }

      auto* recipient = std::ranges::find(result, lease.terminal, &Recipient::terminal);
      if (recipient == result.end()) {
        recipient = std::ranges::find(result, QPointer<TerminalItem>{}, &Recipient::terminal);
        if (recipient == result.end()) {
          continue;
        }

        recipient->terminal = lease.terminal;
      }

      auto& buttons = lease.child.owned() ? recipient->child_buttons : recipient->view_buttons;

      buttons.setFlag(native);
    }

    return result;
  }

  void TerminalController::deliver(TerminalItem& terminal, const QMouseEvent& event, Qt::MouseButtons buttons) {
    QMouseEvent forwarded{event.type(), terminal.mapFromScene(event.position()), event.position(), event.globalPosition(), event.button(), buttons, event.modifiers(), event.source(), event.pointingDevice()};

    forwarded.setTimestamp(event.timestamp());
    QCoreApplication::sendEvent(&terminal, &forwarded);
  }

  void TerminalController::dragPointer(const QMouseEvent& event) {
    const auto destinations = recipients();

    for (const auto& destination : destinations) {
      auto* const terminal = destination.terminal.data();
      if (terminal != nullptr && (destination.child_buttons & event.buttons()) != Qt::NoButton) {
        terminal->observeLinkPointer(terminal->mapFromScene(event.position()), event.modifiers());
        if (destination.child_buttons.testFlag(Qt::LeftButton)) {
          terminal->cancelLinkGesture();
        }
      }
    }

    for (const auto& [native, semantic] : mouse_buttons) {
      auto& lease = captures_[static_cast<std::size_t>(semantic)];
      if (lease.held && lease.child.owned() && event.buttons().testFlag(native)) {
        report(lease.pane_id, lease.child.deliver(view(lease), sample(event, application::terminal::input::MousePhase::drag, semantic)));
      }
    }

    for (const auto& recipient : destinations) {
      const auto held = recipient.view_buttons & event.buttons();
      if (recipient.terminal != nullptr && held != Qt::NoButton) {
        deliver(*recipient.terminal, event, held);
      }
    }
  }

  bool TerminalController::releasePointer(const QMouseEvent& event) {
    auto* lease = capture(event.button());
    if (lease == nullptr || !lease->held) {
      return false;
    }

    auto previous = std::exchange(*lease, Capture{});
    if (previous.child.owned()) {
      report(previous.pane_id, previous.child.deliver(view(previous), sample(event, application::terminal::input::MousePhase::release, mouseButton(event.button()))));
    } else if (previous.terminal != nullptr) {
      Qt::MouseButtons held;

      for (const auto& recipient : recipients()) {
        if (recipient.terminal == previous.terminal) {
          held = recipient.view_buttons & event.buttons();
        }
      }

      deliver(*previous.terminal, event, held);
    }

    return true;
  }

  void TerminalController::observeScroll(TerminalItem& terminal) {
    if (scroll_owner_ != &terminal) {
      retireScroll();
      scroll_owner_ = &terminal;
    }
  }

  void TerminalController::retireScroll() {
    if (!scroll_owner_.isNull() && scroll_owner_->controller() == this && scroll_owner_->window() == window_) {
      scroll_owner_->resetWheel();
    }

    scroll_owner_.clear();
  }

}
