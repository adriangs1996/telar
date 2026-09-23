//! One focused editor's provisional IME text. Committed model text is never
//! modified until commit, so cancellation cannot lose the prior selection.
const std = @import("std");
const Id = @import("Id.zig");
const Preedit = @This();

pub const capacity = 4096;
owner: ?Id = null,
bytes: [capacity]u8 = undefined,
len: u16 = 0,
selection: [2]u32 = .{ 0, 0 },
replacement: [2]u32 = .{ 0, 0 },

/// Owns the preedit before the native callback's text borrow expires.
/// Example: `try preedit.update(id, .{ .composition = value, .current = field });`
pub fn update(self: *Preedit, id: Id, input: @import("PreeditUpdate.zig")) !void {
    const value = input.composition;
    if (value.cancel) {
        self.clear();
        return;
    }

    const provisional: @import("FieldView.zig") = .{ .text = value.text, .head = value.selection_end, .anchor = value.selection_start };
    if (value.text.len > capacity or !std.unicode.utf8ValidateSlice(value.text) or !provisional.validRange(.{ value.selection_start, value.selection_end })) {
        return error.InvalidWidgetComposition;
    }

    const existing = if (self.owner) |owner| owner.eql(id) else false;
    const replacement = if (value.replacement_start != std.math.maxInt(u32)) [2]u32{ value.replacement_start, value.replacement_end } else if (existing) self.replacement else input.current.selection();
    if (replacement[0] > replacement[1] or !input.current.validRange(replacement)) {
        return error.InvalidWidgetComposition;
    }

    @memcpy(self.bytes[0..value.text.len], value.text);
    self.owner = id;
    self.len = @intCast(value.text.len);
    self.selection = .{ value.selection_start, value.selection_end };
    self.replacement = replacement;
}

/// Example: `preedit.clear();`
pub fn clear(self: *Preedit) void {
    self.owner = null;
    self.len = 0;
}

/// Example: `try canvas.textAt(bounds, .{ .text = preedit.text() });`
pub fn text(self: *const Preedit) []const u8 {
    return self.bytes[0..self.len];
}
