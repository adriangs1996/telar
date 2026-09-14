const client = @import("telar-client");
const core = @import("telar-core");
const Modal = @import("Modal.zig");
const EditorView = @import("EditorView.zig");
const CompletionRows = @import("CompletionRows.zig");

pub const create_hints = "tab complete · ↑↓ choose · ↵ create · esc cancel";
pub const create_confirmation = "Directory does not exist · ↵ creates it · esc cancel";

/// Draws name editing and copy search using the same bounded prompt state.
/// Example: `try paint(modal, prompt);`.
pub fn paint(modal: Modal, prompt: client.Prompt) !void {
    const title: []const u8 = switch (prompt.target()) {
        .rename_tab => "Rename tab",
        .rename_workspace => "Rename workspace",
        .copy_search => |direction| if (direction == .forward) "Search forward" else "Search backward",
        else => unreachable,
    };
    try modal.frame(title);

    const content = modal.content();
    try modal.field(content.row(if (content.h > 2) 1 else 0), prompt);

    if (content.h > 2) {
        try modal.line(content.h - 1, .{ .text = "Enter confirm  Esc cancel", .color = modal.canvas.theme.palette.subtext0 });
    }
}

/// Draws the new-context form: name, working directory, the client's landed
/// completion list and either the key hints or the directory confirmation.
/// Example: `try paintCreateForm(modal, projection);`.
pub fn paintCreateForm(modal: Modal, projection: client.Projection) !void {
    var prompt = projection.prompt.?;
    const form = prompt.mode.create_workspace;
    const palette = modal.canvas.theme.palette;
    try modal.frame("New context");

    const content = modal.content();
    if (content.h < 4) {
        const row = content.row(0);
        if (form.focus == .name) {
            try modal.editor(row, EditorView.capture(&prompt.field, row.w, true));
        } else {
            try modal.editor(row, EditorView.capture(&prompt.directory, row.w, true));
        }
        return;
    }

    try modal.line(0, .{ .text = "Name", .color = palette.subtext0 });
    try modal.editor(content.row(1), EditorView.capture(&prompt.field, content.w, form.focus == .name));
    try modal.line(2, .{ .text = "Working directory", .color = palette.subtext0 });
    try modal.editor(content.row(3), EditorView.capture(&prompt.directory, content.w, form.focus == .directory));

    const footer: []const u8 = if (form.confirm_create) create_confirmation else create_hints;
    if (content.h > 5) {
        try modal.line(content.h - 1, .{ .text = footer, .color = if (form.confirm_create) palette.yellow else palette.subtext0 });
    }

    const rows = content.splitTop(@min(content.h, 5))[1].splitBottom(1)[0];
    try paintCompletions(modal, rows, .{ .entries = projection.path_completion.entries(), .selected = prompt.selection(), .active = form.focus == .directory });
}


fn paintCompletions(modal: Modal, rows: core.Rect, input: CompletionRows) !void {
    const palette = modal.canvas.theme.palette;
    if (rows.isEmpty() or input.entries.len == 0) {
        return;
    }

    const selected: usize = @min(input.selected, input.entries.len - 1);
    const count = @min(rows.h, input.entries.len);
    const start = (selected + 1) -| count;
    for (0..count) |offset| {
        const index = start + offset;
        const row = rows.row(@intCast(offset));
        const highlighted = input.active and index == selected;
        if (highlighted) {
            try modal.canvas.fill(row, palette.surface1);
        }

        try modal.canvas.text(row, .{ .text = input.entries[index].slice(), .color = if (highlighted) palette.accent else palette.text, .bold = highlighted });
    }
}
