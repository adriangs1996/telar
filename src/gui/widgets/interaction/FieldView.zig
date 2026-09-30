//! A synchronous read of the authoritative prompt field, never retained.
const shared_model = @import("model");
const std = @import("std");
const client = @import("telar-client");
const Target = @import("Target.zig");
const FieldView = @This();

text: []const u8,
head: u32,
anchor: u32,
/// Bytes the field holds at most; a field whose owner bounds its own edits
/// leaves it open.
capacity: u32 = std.math.maxInt(u32),

/// Rejects a retired prompt generation before borrowing its replacement.
/// Example: `const field = FieldView.capture(prompt, target) orelse return;`
pub fn capture(prompt: *const shared_model.Prompt, target: Target) ?FieldView {
    if (target.action != .text_field or prompt.generation != target.id.generation) {
        return null;
    }

    if (target.action.text_field == .directory) {
        if (prompt.form() == null) {
            return null;
        }

        return .{ .text = prompt.directory.text(), .head = @intCast(prompt.directory.head), .anchor = @intCast(prompt.directory.anchor), .capacity = prompt.directory.bytes.len };
    }

    return .{ .text = prompt.field.text(), .head = @intCast(prompt.field.head), .anchor = @intCast(prompt.field.anchor), .capacity = prompt.field.bytes.len };
}

/// Resolves a delivered editor against its current prompt or pane attachment.
/// Example: `const field = FieldView.captureClient(app, target) orelse return;`
pub fn captureClient(app: *const client.Client, target: Target) ?FieldView {
    const prompt = app.model.name_prompt.currentConst() orelse return null;
    return capture(prompt, target);
}

/// Reads the edit revision of the prompt whose text `captureClient` borrows.
/// Example: `const revision = FieldView.revision(app);`
pub fn revision(app: *const client.Client) u64 {
    return app.model.name_prompt.version();
}

/// Example: `const selected = field.selection();`
pub fn selection(self: FieldView) [2]u32 {
    return .{ @min(self.head, self.anchor), @max(self.head, self.anchor) };
}

/// Validates native byte offsets without copying the field or changing it.
/// Example: `if (!field.validRange(range)) return;`
pub fn validRange(self: FieldView, range: [2]u32) bool {
    return self.boundary(range[0]) and self.boundary(range[1]);
}

/// The prefix of `bytes` that fits in place of `range`, cut at a UTF-8
/// boundary; all of it when it fits.
/// Example: `const kept = field.fitting(range, pasted);`
pub fn fitting(self: FieldView, range: [2]u32, bytes: []const u8) []const u8 {
    const replaced = range[1] -| range[0];
    const room = self.capacity -| (@as(u32, @intCast(self.text.len)) -| replaced);
    var len: usize = @min(bytes.len, room);
    while (len > 0 and len < bytes.len and bytes[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    return bytes[0..len];
}

fn boundary(self: FieldView, at: u32) bool {
    return at <= self.text.len and (at == self.text.len or self.text[at] & 0xc0 != 0x80);
}

test "a paste keeps the prefix that fits the field at a UTF-8 boundary" {
    const field: FieldView = .{ .text = "tab", .head = 3, .anchor = 3, .capacity = 8 };
    try std.testing.expectEqualStrings("12345", field.fitting(.{ 3, 3 }, "123456789"));
    try std.testing.expectEqualStrings("1234", field.fitting(.{ 3, 3 }, "1234\u{e9}"));
    try std.testing.expectEqualStrings("12345678", field.fitting(.{ 0, 3 }, "123456789"));
    try std.testing.expectEqualStrings("ok", field.fitting(.{ 3, 3 }, "ok"));
}
