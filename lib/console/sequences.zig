//! Terminal mode sequences shared by host platform adapters.

/// Returns the host pointer to its default shape (OSC 22).
pub const reset_pointer = "\x1b]22;default\x1b\\";

pub const leave =
    reset_pointer ++
    "\x1b[<u" ++
    "\x1b[?2004l" ++
    "\x1b[?1016l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l" ++
    "\x1b[?25h" ++
    "\x1b[?1049l";
