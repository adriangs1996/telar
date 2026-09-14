//! One focused editor's provisional IME text. Committed model text is never
//! modified until commit, so cancellation cannot lose the prior selection.
const std = @import("std");
const Id = @import("Id.zig");
const Composition = @import("../../input/Composition.zig");
const Preedit = @This();

pub const capacity = 4096;
owner: ?Id = null,
bytes: [capacity]u8 = undefined,
len: u16 = 0,
selection: [2]u32 = .{ 0, 0 },
replacement: [2]u32 = .{ 0, 0 },

/// Owns the preedit before the native callback's text borrow expires.
/// Example: `try preedit.update(id, .{ .composition = value, .current = field });`
pub fn update(preedit: *Preedit, id: Id, input: @import("PreeditUpdate.zig")) !void {
    const value = input.composition;
    if (value.cancel) {
        preedit.clear();
        return;
    }

    const provisional: @import("FieldView.zig") = .{ .text = value.text, .head = value.selection_end, .anchor = value.selection_start };
    if (value.text.len > capacity or !std.unicode.utf8ValidateSlice(value.text) or !provisional.validRange(.{ value.selection_start, value.selection_end })) {
        return error.InvalidWidgetComposition;
    }

    const existing = if (preedit.owner) |owner| owner.eql(id) else false;
    const replacement = if (value.replacement_start != std.math.maxInt(u32)) [2]u32{ value.replacement_start, value.replacement_end } else if (existing) preedit.replacement else input.current.selection();
    if (replacement[0] > replacement[1] or !input.current.validRange(replacement)) {
        return error.InvalidWidgetComposition;
    }

    @memcpy(preedit.bytes[0..value.text.len], value.text);
    preedit.owner = id;
    preedit.len = @intCast(value.text.len);
    preedit.selection = .{ value.selection_start, value.selection_end };
    preedit.replacement = replacement;
}

/// Example: `preedit.clear();`
pub fn clear(preedit: *Preedit) void {
    preedit.owner = null;
    preedit.len = 0;
}

/// Example: `try canvas.textAt(bounds, .{ .text = preedit.text() });`
pub fn text(preedit: *const Preedit) []const u8 {
    return preedit.bytes[0..preedit.len];
}
