#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/fonts/font_resolver.hpp"
#include <QKeyEvent>
#include <QtCore/qtypes.h>
#include <cstdint>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  class TerminalItem;

  // What a terminal's input needs from the window it is in, which only the window can do: its key
  // bindings and the views that take a pane's keys before its terminal, the pane's focus, the
  // pointer gestures over the whole window, opening links, and the window's font. The window
  // implements it; each input event a terminal receives costs at most one of these calls.
  class TerminalHost {
  public:
    TerminalHost(const TerminalHost&) = delete;
    TerminalHost& operator=(const TerminalHost&) = delete;
    TerminalHost(TerminalHost&&) = delete;
    TerminalHost& operator=(TerminalHost&&) = delete;

    // A key press the terminal has the focus for. The window's bindings take it first, then an
    // inline document over the pane; the window hands what they leave to terminal.type().
    virtual void pressKey(TerminalItem& terminal, QKeyEvent& event) = 0;
    // A key release, which the window's bindings may take. False leaves it to the terminal.
    [[nodiscard]] virtual bool releaseKey(TerminalItem& terminal, QKeyEvent& event) = 0;
    // An input method is about to commit text: a pending key sequence ends.
    virtual void interruptKeys() = 0;
    // A press on the terminal's cells focuses its pane.
    virtual void focusPane(TerminalItem& terminal) = 0;
    // The terminal lost the pointer it grabbed: the window cancels its pointer gestures.
    virtual void ungrabPointer(TerminalItem& terminal) = 0;
    virtual void openLink(const application::terminal::links::LinkTarget& target, std::uint64_t pane_id) = 0;
    // The configured font, at the density of the terminal's window.
    [[nodiscard]] virtual ResolvedFont resolveFont(qreal scale) = 0;

  protected:
    TerminalHost() = default;
    ~TerminalHost() = default;
  };

}
