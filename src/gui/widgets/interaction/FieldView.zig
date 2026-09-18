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

/// Resolves a delivered editor against its current prompt or pane attachment.
/// Example: `const field = FieldView.captureClient(app, target) orelse return;`
pub fn captureClient(app: *const client.AttachedClient, target: Target) ?FieldView {
    if (target.action == .composer) {
        if (app.model.name_prompt.active()) {
            return null;
        }

        const model = app.model.activeTabModelConst() orelse return null;
        const pane = model.findConst(target.action.composer) orelse return null;
        if (!pane.attached or pane.kind != .agent or pane.attachment_generation != target.id.generation) {
            return null;
        }

        const value = pane.composer_field;
        return .{ .text = value.text(), .head = @intCast(value.head), .anchor = @intCast(value.anchor) };
    }

    const prompt = app.model.name_prompt.currentConst() orelse return null;
    return capture(prompt, target);
}

/// Reads the edit revision in the same owner scope used to capture text.
/// Example: `const revision = FieldView.revision(app, target);`
pub fn revision(app: *const client.AttachedClient, target: Target) u64 {
    if (target.action == .composer) {
        const model = app.model.activeTabModelConst() orelse return 0;
        const pane = model.findConst(target.action.composer) orelse return 0;
        return if (pane.attachment_generation == target.id.generation) pane.composer_revision else 0;
    }

    return app.model.name_prompt.version();
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
