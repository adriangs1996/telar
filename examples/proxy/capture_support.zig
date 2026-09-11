const std = @import("std");
const vt = @import("ghostty-vt");

// Bounded capture of what one command printed, resolved to plain text.
//
// Feeding the bytes through a real terminal is the whole point. Raw output is
// mostly cursor moves and redraws: a `docker pull` is half a megabyte of bytes
// for ten lines of text, and a progress bar is the same line rewritten a
// thousand times. What lands here is what you would have *seen*, which is also
// the only form worth putting in a database and handing to an agent.
//
// This is the advantage a multiplexer has over a shell-level history tool:
// Atuin would have to redirect the stream and keep the bytes; herdr already
// owns a terminal emulator.

pub const Capture = @import("Capture.zig");
