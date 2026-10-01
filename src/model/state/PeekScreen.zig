const core = @import("telar-core");
const std = @import("std");
const AgentKey = @import("../agents/AgentKey.zig");
/// The last rows of the pane a peek shows, as the runtime last read them.
/// Disposable client state: it lives while the peek is open.
const PeekScreen = @This();

/// Bytes of pane text a peek keeps: every row of a 256-column pane at four
/// bytes a cell.
pub const max_text_bytes = rows * max_row_cells * max_cell_bytes;
pub const text_limit = core.Limit.declare("peek.text_bytes", "bytes", max_text_bytes);
/// Rows a peek asks the runtime for.
pub const rows = 16;
const max_row_cells = 256;
const max_cell_bytes = 4;

agent: ?AgentKey = null,
text: [max_text_bytes]u8 = undefined,
text_len: usize = 0,
/// Whether a read is on its way, so snapshots do not queue duplicates.
reading: bool = false,
revision: u64 = 0,

/// Starts showing `agent`, dropping the text of any earlier one.
/// Example: `model.peek_screen.show(key);`.
pub fn show(self: *PeekScreen, agent: AgentKey) void {
    self.agent = agent;
    self.text_len = 0;
    self.reading = false;
    self.revision +%= 1;
}

/// Stores one read, keeping its last bytes from a character on. Returns
/// the bytes it left out, or null when the read is not for this peek.
/// Example: `const dropped = model.peek_screen.store(key.pane_id, text) orelse return;`.
pub fn store(self: *PeekScreen, pane_id: core.PaneId, text: []const u8) ?usize {
    self.reading = false;
    const agent = self.agent orelse return null;
    if (agent.pane_id != pane_id) {
        return null;
    }

    var start = text.len -| max_text_bytes;
    while (start > 0 and start < text.len and text[start] & continuation_mask == continuation_bits) {
        start += 1;
    }

    const kept = text[start..];
    @memcpy(self.text[0..kept.len], kept);
    self.text_len = kept.len;
    self.revision +%= 1;
    return start;
}

const continuation_mask: u8 = 0b1100_0000;
const continuation_bits: u8 = 0b1000_0000;

test "a read longer than the peek keeps its last bytes from a character on" {
    var screen: PeekScreen = .{};
    const key: AgentKey = .{
        .pane_id = @enumFromInt(4),
        .pane_generation = 1,
    };
    screen.show(key);

    const fits = "x" ** max_text_bytes;
    try std.testing.expectEqual(@as(?usize, 0), screen.store(key.pane_id, fits));
    try std.testing.expectEqual(max_text_bytes, screen.slice().len);

    // "é" is two bytes, so the byte the bound would start at is its second.
    const long = "é" ++ "y" ** (max_text_bytes - 1);
    try std.testing.expectEqual(@as(?usize, 2), screen.store(key.pane_id, long));
    try std.testing.expectEqualStrings("y" ** (max_text_bytes - 1), screen.slice());
    try std.testing.expect(screen.store(@enumFromInt(5), long) == null);
}

/// Stops showing any pane. Example: `model.peek_screen.close();`.
pub fn close(self: *PeekScreen) void {
    self.agent = null;
    self.text_len = 0;
    self.reading = false;
    self.revision +%= 1;
}

pub fn slice(self: *const PeekScreen) []const u8 {
    return self.text[0..self.text_len];
}
