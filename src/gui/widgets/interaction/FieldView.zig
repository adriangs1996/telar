//! A synchronous read of the authoritative prompt field, never retained.
const client = @import("telar-client");
const Target = @import("Target.zig");
const FieldView = @This();

text: []const u8,
head: u32,
anchor: u32,

/// Rejects a retired prompt generation before borrowing its replacement.
/// Example: `const field = FieldView.capture(prompt, target) orelse return;`
pub fn capture(prompt: *const client.Prompt, target: Target) ?FieldView {
    if (target.action != .text_field or prompt.generation != target.id.generation) {
        return null;
    }

    if (target.action.text_field == .directory) {
        if (prompt.form() == null) {
            return null;
        }

        return .{ .text = prompt.directory.text(), .head = @intCast(prompt.directory.head), .anchor = @intCast(prompt.directory.anchor) };
    }

    return .{ .text = prompt.field.text(), .head = @intCast(prompt.field.head), .anchor = @intCast(prompt.field.anchor) };
}

/// Example: `const selected = field.selection();`
pub fn selection(field: FieldView) [2]u32 {
    return .{ @min(field.head, field.anchor), @max(field.head, field.anchor) };
}

/// Validates native byte offsets without copying the field or changing it.
/// Example: `if (!field.validRange(range)) return;`
pub fn validRange(field: FieldView, range: [2]u32) bool {
    return field.boundary(range[0]) and field.boundary(range[1]);
}

fn boundary(field: FieldView, at: u32) bool {
    return at <= field.text.len and (at == field.text.len or field.text[at] & 0xc0 != 0x80);
}
