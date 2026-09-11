const std = @import("std");
const Envelope = @import("Envelope.zig");
const rpc = @import("rpc.zig");
/// One parsed record. `text` borrows the parse arena, so copy it before
/// `deinit`.
const Record = @This();

parsed: std.json.Parsed(Envelope),
kind: rpc.Kind,

/// The assistant text of a `get_last_assistant_text` reply, or null when
/// the session holds no assistant message.
///
/// ```zig
/// const text = record.text() orelse return;
/// ```
pub fn text(record: *const Record) ?[]const u8 {
    const data = record.parsed.value.data orelse return null;
    return data.text;
}

pub fn deinit(record: *Record) void {
    record.parsed.deinit();
}
