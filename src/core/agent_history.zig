//! Bounds and navigation shared by history requests and disposable reading windows.
pub const max_cursor_bytes = 2048;
pub const Direction = enum(u8) { older, newer };
