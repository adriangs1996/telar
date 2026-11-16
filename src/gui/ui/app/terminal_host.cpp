#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/terminal/terminal_item.hpp"
#include <QKeyEvent>
#include <cstdint>

import telar.gui.links.cell_links;

namespace telar::gui::qt {

  void ApplicationController::initializeTerminals() {
    // After the window's own slots, which ran before the terminals' when they listened here.
    connect(this, &ApplicationController::configurationChanged, &terminals_, &TerminalController::configurationChanged);
    connect(this, &ApplicationController::machineChanged, &terminals_, &TerminalController::machineChanged);
    connect(this, &ApplicationController::dialogChanged, &terminals_, &TerminalController::dialogChanged);
    connect(&terminals_, &TerminalController::notificationPublished, &notifications_, &NotificationsController::refresh);
    connect(&terminals_, &TerminalController::failed, this, &ApplicationController::reportFailure);
  }

  void ApplicationController::pressKey(TerminalItem& terminal, QKeyEvent& event) {
    if (handleBindingKey(event, terminal, terminal.composing())) {
      return;
    }

    const auto pane_id = terminal.paneIdentity();
    // An inline document the pane shows takes its scroll keys before the terminal.
    if (!terminal.composing() && documents_.key(pane_id, event)) {
      terminal.wakeCursor();
    } else if (const auto typed = terminal.type(event)) {
      attachments_.key(pane_id, *typed);
    }
  }

  bool ApplicationController::releaseKey(TerminalItem& terminal, QKeyEvent& event) {
    return handleBindingKey(event, terminal, terminal.composing());
  }

  void ApplicationController::interruptKeys() {
    key_bindings_.interrupt();
  }

  void ApplicationController::focusPane(TerminalItem& terminal) {
    execute(Action::focus_pane, terminal.paneId());
  }

  void ApplicationController::ungrabPointer(TerminalItem& terminal) {
    pointer_dispatcher_.ungrab(terminal);
  }

  void ApplicationController::openLink(const LinkTarget& target, std::uint64_t pane_id) {
    static_cast<void>(links_.open(target, pane_id));
  }

}
