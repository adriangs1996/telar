const core = @import("telar-core");
const std = @import("std");
const PaneKey = @import("PaneKey.zig");
/// The final text and exit status of the panes that exited last, so a
/// command that finished before anyone read it can still be read: a test run
/// or a linter launched by automation often exits within a second. A bounded
/// ring; the oldest record makes room.
const ExitedPanes = @This();

pub const capacity = 16;
/// Rows of scrollback and screen kept per pane.
pub const kept_rows = core.max_pane_text_rows;
pub const max_text_bytes = 16 * 1024;

key: [capacity]PaneKey = @splat(.{ .id = .invalid, .generation = 0 }),
exit_code: [capacity]i32 = @splat(0),
text: [capacity][max_text_bytes]u8 = undefined,
text_len: [capacity]u16 = @splat(0),
next: usize = 0,

/// Stores one exited pane's final text, replacing the oldest record.
///
/// ```zig
/// store.exited.record(pane.key(), exit.code(), dump);
/// ```
pub fn record(self: *ExitedPanes, key: PaneKey, exit_code: i32, text: []const u8) void {
    const slot = self.next;
    self.next = (self.next + 1) % capacity;
    const kept = text[text.len -| max_text_bytes..];
    self.key[slot] = key;
    self.exit_code[slot] = exit_code;
    @memcpy(self.text[slot][0..kept.len], kept);
    self.text_len[slot] = @intCast(kept.len);
}

/// The record of `key`; generation zero names the newest pane with its id.
///
/// ```zig
/// const slot = store.exited.find(key) orelse return notFound();
/// ```
pub fn find(self: *const ExitedPanes, key: PaneKey) ?usize {
    var index: usize = 0;
    while (index < capacity) : (index += 1) {
        const slot = (self.next + capacity - 1 - index) % capacity;
        if (self.key[slot].id != key.id or key.id == .invalid) {
            continue;
        }

        if (key.generation == 0 or self.key[slot].generation == key.generation) {
            return slot;
        }
    }

    return null;
}

/// The last `rows` lines of a record's text.
///
/// ```zig
/// const tail = store.exited.tail(slot, 40);
/// ```
pub fn tail(self: *const ExitedPanes, slot: usize, rows: usize) []const u8 {
    const text = std.mem.trimEnd(u8, self.text[slot][0..self.text_len[slot]], "\n ");
    var start = text.len;
    var lines: usize = 0;
    while (start > 0) : (start -= 1) {
        if (text[start - 1] == '\n') {
            lines += 1;
            if (lines == rows) {
                break;
            }
        }
    }

    return text[start..];
}

test "exited panes keep their newest records and answer by generation" {
    var exited: ExitedPanes = .{};
    const first: PaneKey = .{ .id = @enumFromInt(3), .generation = 7 };
    exited.record(first, 1, "one\ntwo\nthree\n");
    try std.testing.expectEqual(@as(i32, 1), exited.exit_code[exited.find(first).?]);
    try std.testing.expectEqualStrings("two\nthree", exited.tail(exited.find(.{ .id = first.id, .generation = 0 }).?, 2));
    try std.testing.expect(exited.find(.{ .id = first.id, .generation = 8 }) == null);

    for (0..capacity) |index| {
        exited.record(.{ .id = @enumFromInt(100 + index), .generation = 1 }, 0, "x");
    }

    try std.testing.expect(exited.find(first) == null);
}
