#pragma once

#include "qt/terminal_item.hpp"

namespace telar::gui::test {

class TerminalCursor final {
public:
  explicit TerminalCursor(qt::TerminalItem &terminal)
      : terminal_(terminal),
        visible_(terminal.cursor_on_),
        blinking_(terminal.blink_.isActive()) {
    terminal_.blink_.stop();
  }

  ~TerminalCursor() {
    setVisible(visible_);
    if (blinking_) {
      terminal_.blink_.start();
    }
  }

  TerminalCursor(const TerminalCursor &) = delete;
  TerminalCursor &operator=(const TerminalCursor &) = delete;
  TerminalCursor(TerminalCursor &&) = delete;
  TerminalCursor &operator=(TerminalCursor &&) = delete;

  void setVisible(bool visible) {
    terminal_.cursor_on_ = visible;
    terminal_.update();
  }

private:
  qt::TerminalItem &terminal_;
  bool visible_;
  bool blinking_;
};

}
