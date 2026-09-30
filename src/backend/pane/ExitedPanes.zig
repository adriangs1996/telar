const std = @import("std");
const PaneKey = @import("PaneKey.zig");
const TextTail = @import("TextTail.zig");
/// The final text and exit status of the panes that exited last, so a
/// command that finished before anyone read it can still be read: a test run
/// or a linter launched by automation often exits within a second. A bounded
/// ring; the oldest record makes room.
const ExitedPanes = @This();

pub const capacity = 16;
/// Rows of scrollback and screen kept per pane: about what
/// `max_text_bytes` holds, so a pane's exit walks no rows it cannot keep.
pub const kept_rows = 200;
pub const max_text_bytes = 16 * 1024;

key: [capacity]PaneKey = @splat(.{ .id = .invalid, .generation = 0 }),
exit_code: [capacity]i32 = @splat(0),
text: [capacity][max_text_bytes]u8 = undefined,
text_len: [capacity]u16 = @splat(0),
/// Whether older rows of the pane's output did not fit in `text`.
truncated: [capacity]bool = @splat(false),
next: usize = 0,

/// Stores one exited pane's final text, replacing the oldest record. The
/// dump holds the newest rows; its `truncated` says older ones were dropped.
///
/// ```zig
/// store.exited.record(pane.key(), exit.code(), .{ .text = dump, .truncated = true });
/// ```
pub fn record(self: *ExitedPanes, key: PaneKey, exit_code: i32, dump: TextTail) void {
    const slot = self.next;
    self.next = (self.next + 1) % capacity;
    const kept = dump.text[dump.text.len -| max_text_bytes..];
    self.key[slot] = key;
    self.exit_code[slot] = exit_code;
    @memcpy(self.text[slot][0..kept.len], kept);
    self.text_len[slot] = @intCast(kept.len);
    self.truncated[slot] = dump.truncated or kept.len != dump.text.len;
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

/// The last `rows` lines of a record's text. The tail is truncated when it
/// reaches the first kept line and older lines were dropped.
///
/// ```zig
/// const tail = store.exited.tail(slot, 40);
/// ```
pub fn tail(self: *const ExitedPanes, slot: usize, rows: usize) TextTail {
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

    return .{
        .text = text[start..],
        .truncated = start == 0 and self.truncated[slot],
    };
}

test "exited panes keep their newest records and answer by generation" {
    var exited: ExitedPanes = .{};
    const first: PaneKey = .{ .id = @enumFromInt(3), .generation = 7 };
    exited.record(first, 1, .{
        .text = "one\ntwo\nthree\n",
        .truncated = false,
    });
    try std.testing.expectEqual(@as(i32, 1), exited.exit_code[exited.find(first).?]);
    try std.testing.expectEqualStrings("two\nthree", exited.tail(exited.find(.{ .id = first.id, .generation = 0 }).?, 2).text);
    try std.testing.expect(exited.find(.{ .id = first.id, .generation = 8 }) == null);

    for (0..capacity) |index| {
        exited.record(.{ .id = @enumFromInt(100 + index), .generation = 1 }, 0, .{
            .text = "x",
            .truncated = false,
        });
    }

    try std.testing.expect(exited.find(first) == null);
}

test "a tail reports truncation only when it reaches lines that were dropped" {
    var exited: ExitedPanes = .{};
    const key: PaneKey = .{ .id = @enumFromInt(3), .generation = 7 };
    exited.record(key, 0, .{
        .text = "two\nthree\n",
        .truncated = true,
    });
    const slot = exited.find(key).?;

    try std.testing.expectEqualStrings("three", exited.tail(slot, 1).text);
    try std.testing.expect(!exited.tail(slot, 1).truncated);
    try std.testing.expectEqualStrings("two\nthree", exited.tail(slot, 5).text);
    try std.testing.expect(exited.tail(slot, 5).truncated);
}
