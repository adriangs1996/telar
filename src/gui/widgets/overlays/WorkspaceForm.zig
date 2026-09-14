//! The workspace name, directory editor and landed completion rows.
const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../Canvas.zig");
const Modal = @import("Modal.zig");
const CompletionRows = @import("CompletionRows.zig");
const TextField = @import("../TextField.zig");
const WorkspaceForm = @This();

pub const create_hints = "tab complete · ↑↓ choose · enter create · esc cancel";
pub const create_confirmation = "Directory does not exist · enter creates it · esc cancel";

area: core.Rect,
projection: *const client.Projection,

/// Example: `try form.draw(canvas);`
pub fn draw(widget: WorkspaceForm, canvas: *Canvas) !void {
    const modal: Modal = .{ .area = widget.area, .title = "New context" };
    const projection = widget.projection.*;
    var prompt = projection.prompt.?;
    const form = prompt.mode.create_workspace;
    const palette = canvas.theme.palette;
    try modal.draw(canvas);

    const content = modal.content();
    if (content.h < 4) {
        const row = content.row(0);
        if (form.focus == .name) {
            try TextField.fromPrompt(&prompt, canvas.rect(row), .name).draw(canvas);
        } else {
            try TextField.fromPrompt(&prompt, canvas.rect(row), .directory).draw(canvas);
        }
        return;
    }

    try canvas.text(content.row(0), .{ .text = "Name", .color = palette.subtext0, .face = .sans, .size = .body });
    try TextField.fromPrompt(&prompt, canvas.rect(content.row(1)), .name).draw(canvas);
    try canvas.text(content.row(2), .{ .text = "Working directory", .color = palette.subtext0, .face = .sans, .size = .body });
    try TextField.fromPrompt(&prompt, canvas.rect(content.row(3)), .directory).draw(canvas);

    const footer: []const u8 = if (form.confirm_create) create_confirmation else create_hints;
    if (content.h > 5) {
        try canvas.text(content.row(content.h - 1), .{ .text = footer, .color = if (form.confirm_create) palette.yellow else palette.subtext0, .face = .sans, .size = .body });
    }

    const rows = content.splitTop(@min(content.h, 5))[1].splitBottom(1)[0];
    try drawCompletions(canvas, rows, .{ .entries = projection.path_completion.entries(), .selected = prompt.selection(), .active = form.focus == .directory });
}

fn drawCompletions(canvas: *Canvas, rows: core.Rect, input: CompletionRows) !void {
    const palette = canvas.theme.palette;
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
            try canvas.fill(row, palette.surface1);
        }

        try canvas.text(row, .{ .text = input.entries[index].slice(), .color = if (highlighted) palette.accent else palette.text, .bold = highlighted });
    }
}
