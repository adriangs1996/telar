//! Terminal mode sequences shared by host platform adapters.

const reset_pointer = "\x1b]22;default\x1b\\";

pub const enter =
    "\x1b[?1049h" ++
    "\x1b[?25l" ++
    "\x1b[?1000h" ++
    "\x1b[?1002h" ++
    "\x1b[?1003h" ++
    "\x1b[?1006h" ++
    "\x1b[?1016h" ++
    "\x1b[?2004h" ++
    "\x1b[>7u" ++
    "\x1b[2J";

pub const leave =
    reset_pointer ++
    "\x1b[<u" ++
    "\x1b[?2004l" ++
    "\x1b[?1016l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l" ++
    "\x1b[?25h" ++
    "\x1b[?1049l";

pub const pane_enter =
    "\x1b[?1049h" ++
    "\x1b[?25l" ++
    "\x1b[2J";

pub const pane_leave =
    "\x1b[?25h" ++
    "\x1b[?1049l";
