#pragma once

#include "terminal.hpp"

namespace telar::runtime {

enum class TrailingSpaces : bool {
  kept,
  trimmed
};

// Plain text of `selection`. Pane reads keep the spaces a program wrote, as
// Zig's `Screen.dumpString`; copies trim them, as `Screen.selectionString`.
template <Allocator Memory>
void formatTerminalSelection(Terminal<Memory> &terminal, const GhosttySelection &selection, bool unwrap, TrailingSpaces spaces, GhosttyWriter writer) {
  auto options = ghosttySized<GhosttyFormatterTerminalOptions>();
  options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  options.unwrap = unwrap;
  options.trim = spaces == TrailingSpaces::trimmed;
  options.selection = &selection;
  options.extra = ghosttySized<GhosttyFormatterTerminalExtra>();
  options.extra.screen = ghosttySized<GhosttyFormatterScreenExtra>();
  FormatterHandle formatter;
  checkGhostty(ghostty_formatter_terminal_new(terminal.allocator(), formatter.output(), terminal.handle(), options));
  checkGhostty(ghostty_formatter_format(formatter.get(), writer));
}

}
