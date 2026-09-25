//! A synchronous read of the authoritative prompt field, never retained.
const shared_model = @import("model");
const client = @import("telar-client");
const Target = @import("Target.zig");
const FieldView = @This();

text: []const u8,
head: u32,
anchor: u32,

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

        return .{ .text = prompt.directory.text(), .head = @intCast(prompt.directory.head), .anchor = @intCast(prompt.directory.anchor) };
    }

    return .{ .text = prompt.field.text(), .head = @intCast(prompt.field.head), .anchor = @intCast(prompt.field.anchor) };
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

fn boundary(self: FieldView, at: u32) bool {
    return at <= self.text.len and (at == self.text.len or self.text[at] & 0xc0 != 0x80);
}
