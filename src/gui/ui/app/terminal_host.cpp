#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include <QKeyEvent>
#include <cstdint>

import telar.gui.links.cell_links;

namespace telar::gui::qt {

  void ApplicationController::pressKey(TerminalItem& terminal, QKeyEvent& event) {
    if (commands_.handleKey(event, terminal, terminal.composing())) {
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
    return commands_.handleKey(event, terminal, terminal.composing());
  }

  void ApplicationController::interruptKeys() {
    key_bindings_.interrupt();
  }

  void ApplicationController::focusPane(TerminalItem& terminal) {
    commands_.execute(window_actions::Action::focus_pane, terminal.paneId());
  }

  void ApplicationController::ungrabPointer(TerminalItem& terminal) {
    pointer_dispatcher_.ungrab(terminal);
  }

  void ApplicationController::openLink(const LinkTarget& target, std::uint64_t pane_id) {
    static_cast<void>(links_.open(target, pane_id));
  }

}
