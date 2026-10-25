#pragma once

#include "terminal.hpp"

namespace telar::runtime {

template <Allocator Memory>
void formatTerminalSelection(Terminal<Memory> &terminal, const GhosttySelection &selection, bool unwrap, GhosttyWriter writer) {
  auto options = ghosttySized<GhosttyFormatterTerminalOptions>();
  options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  options.unwrap = unwrap;
  options.trim = true;
  options.selection = &selection;
  options.extra = ghosttySized<GhosttyFormatterTerminalExtra>();
  options.extra.screen = ghosttySized<GhosttyFormatterScreenExtra>();
  FormatterHandle formatter;
  checkGhostty(ghostty_formatter_terminal_new(terminal.allocator(), formatter.output(), terminal.handle(), options));
  checkGhostty(ghostty_formatter_format(formatter.get(), writer));
}

}
