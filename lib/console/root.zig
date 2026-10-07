//! The controlling terminal on every operating system: raw mode, resize
//! notifications, a fast writer, the escape sequences that drive it, a
//! screen that sends only the cells that changed, and the decoder for what
//! the terminal sends back.
const host_input = @import("host_input.zig");
const host_output = @import("host_output.zig");

pub const ClipboardError = host_output.ClipboardError;
pub const Event = host_input.Event;
pub const Parsed = @import("Parsed.zig");
pub const Size = @import("Size.zig");
pub const max_clipboard_bytes = host_output.max_clipboard_bytes;
pub const parse = host_input.parse;
pub const platform = @import("platform.zig");
pub const pointer = @import("pointer.zig");
pub const sequences = @import("sequences.zig");
pub const writeClipboard = host_output.writeClipboard;
pub const writeCursorPosition = host_output.writeCursorPosition;
pub const writeHostNotification = host_output.writeHostNotification;
pub const writeStyle = host_output.writeStyle;
