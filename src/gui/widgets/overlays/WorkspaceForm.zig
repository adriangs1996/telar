//! Native context creation: pixel-sized fields, folder suggestions and actions.
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const TextField = @import("../TextField.zig");
const FormButton = @import("../FormButton.zig");
const FormLayout = @import("WorkspaceFormLayout.zig");
const WorkspaceForm = @This();

layout: FormLayout,
projection: *const client.Projection,

/// Example: `try form.draw(canvas);`
pub fn draw(widget: WorkspaceForm, canvas: *Canvas) !void {
    const layout = widget.layout;
    try (@import("DialogSurface.zig"){ .bounds = layout.bounds, .viewport = layout.viewport }).draw(canvas);
    const first = canvas.quads.items().len;
    try widget.header(canvas);
    if (layout.compact) {
        const field: @import("../interaction/Target.zig").Field = if (widget.projection.prompt.?.mode.create_workspace.focus == .name) .name else .directory;
        var editor = TextField.fromPrompt(&widget.projection.prompt.?, layout.directory, field);
        editor.form_control = true;
        editor.placeholder = if (field == .name) "Context name" else "Working directory";
        try editor.draw(canvas);
    } else {
        try widget.fields(canvas);
        try widget.completions(canvas);
    }

    try widget.footer(canvas);
    canvas.quads.clipFrom(first, layout.bounds);
}

fn header(widget: WorkspaceForm, canvas: *Canvas) !void {
    const layout = widget.layout;
    const close_width = @min(layout.header.width, canvas.chrome.px(28));
    const title: Rect = .{ .x = layout.header.x, .y = layout.header.y, .width = @max(0, layout.header.width - close_width - canvas.chrome.px(8)), .height = @min(layout.header.height, layout.heading_height) };
    var heading = canvas.*;
    heading.chrome.title = @intFromFloat(@max(canvas.chrome.px(20), @as(f32, @floatFromInt(canvas.chrome.title))));
    _ = try heading.textAt(title, .{ .text = "New context", .color = canvas.theme.palette.text, .bold = true, .face = .sans, .size = .title });
    try (FormButton{ .bounds = .{ .x = layout.header.x + layout.header.width - close_width, .y = layout.header.y, .width = close_width, .height = @min(close_width, layout.header.height) }, .text = "×", .label = "Close new context", .action = .{ .prompt = .cancel }, .generation = widget.projection.prompt.?.generation, .namespace = 1, .quiet = true }).draw(canvas);
    if (!layout.compact) {
        _ = try canvas.textAt(.{ .x = layout.header.x, .y = layout.header.y + layout.heading_height + canvas.chrome.px(4), .width = layout.header.width, .height = layout.label_height }, .{ .text = "A workspace for your project.", .face = .sans, .size = .body, .color = canvas.theme.palette.subtext0 });
    }
}

fn fields(widget: WorkspaceForm, canvas: *Canvas) !void {
    const layout = widget.layout;
    const palette = canvas.theme.palette;
    const gap = canvas.chrome.px(6);
    const name_label: Rect = .{ .x = layout.name.x, .y = layout.name.y, .width = layout.name.width, .height = layout.label_height };
    const label_width = try canvas.textAt(name_label, .{ .text = "Name", .face = .sans, .size = .body, .color = palette.text, .bold = true });
    _ = try canvas.textAt(.{ .x = name_label.x + label_width + gap, .y = name_label.y, .width = @max(0, name_label.width - label_width - gap), .height = name_label.height }, .{ .text = "Optional", .face = .sans, .size = .small, .color = palette.subtext0 });
    var name = TextField.fromPrompt(&widget.projection.prompt.?, .{ .x = layout.name.x, .y = layout.name.y + layout.label_height + gap, .width = layout.name.width, .height = layout.field_height }, .name);
    name.form_control = true;
    name.label = "Context name";
    name.placeholder = "e.g. payments-api";
    try name.draw(canvas);
    _ = try canvas.textAt(.{ .x = layout.name.x, .y = name.bounds.y + name.bounds.height + gap, .width = layout.name.width, .height = layout.small_height }, .{ .text = "Defaults to the folder name.", .face = .sans, .size = .small, .color = palette.subtext0 });

    _ = try canvas.textAt(.{ .x = layout.directory.x, .y = layout.directory.y, .width = layout.directory.width, .height = layout.label_height }, .{ .text = "Working directory", .face = .sans, .size = .body, .color = palette.text, .bold = true });
    var directory = TextField.fromPrompt(&widget.projection.prompt.?, .{ .x = layout.directory.x, .y = layout.directory.y + layout.label_height + gap, .width = layout.directory.width, .height = layout.field_height }, .directory);
    directory.form_control = true;
    directory.placeholder = "~/projects/my-app";
    try directory.draw(canvas);
    if (widget.projection.prompt.?.mode.create_workspace.confirm_create) {
        const notice: Rect = .{ .x = layout.directory.x, .y = directory.bounds.y + directory.bounds.height + canvas.chrome.px(10), .width = layout.directory.width, .height = layout.small_height * 2 + canvas.chrome.px(16) };
        try canvas.fillRoundedAt(notice, .{ .color = palette.surface0, .radius = canvas.chrome.px(7) });
        const text: Rect = .{ .x = notice.x + canvas.chrome.px(12), .y = notice.y + canvas.chrome.px(8), .width = @max(0, notice.width - canvas.chrome.px(24)), .height = layout.small_height };
        _ = try canvas.textAt(text, .{ .text = "Folder does not exist", .face = .sans, .size = .small, .bold = true, .color = palette.yellow });
        _ = try canvas.textAt(.{ .x = text.x, .y = text.y + layout.small_height, .width = text.width, .height = text.height }, .{ .text = "Create it with this context.", .face = .sans, .size = .small, .color = palette.subtext0 });
    }
}

fn completions(widget: WorkspaceForm, canvas: *Canvas) !void {
    const layout = widget.layout;
    if (layout.rows == 0) {
        return;
    }

    const completion = widget.projection.path_completion;
    const entries = completion.entries();
    const selected = @min(widget.projection.prompt.?.selection(), entries.len - 1);
    const start = (selected + 1) -| layout.rows;
    _ = try canvas.textAt(.{ .x = layout.directory.x, .y = layout.suggestions.y - layout.small_height - canvas.chrome.px(6), .width = layout.directory.width, .height = layout.small_height }, .{ .text = "Folders", .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 });
    for (0..layout.rows) |offset| {
        const index = start + offset;
        try (@import("DirectorySuggestion.zig"){ .bounds = layout.completionRow(offset), .name = entries[index].slice(), .choice = .{ .index = @intCast(index), .revision = completion.version() }, .generation = widget.projection.prompt.?.generation, .selected = index == selected, .enabled = completion.pending == .none }).draw(canvas);
    }

    if (entries.len > layout.rows) {
        const unit = layout.suggestions.height / @as(f32, @floatFromInt(entries.len));
        try canvas.fillRoundedAt(.{ .x = layout.suggestions.x + layout.suggestions.width - canvas.chrome.px(3), .y = layout.suggestions.y + @as(f32, @floatFromInt(start)) * unit, .width = canvas.chrome.px(3), .height = @as(f32, @floatFromInt(layout.rows)) * unit }, .{ .color = canvas.theme.palette.overlay0, .radius = canvas.chrome.px(2) });
    }
}

fn footer(widget: WorkspaceForm, canvas: *Canvas) !void {
    const layout = widget.layout;
    const prompt = widget.projection.prompt.?;
    const confirm = prompt.mode.create_workspace.confirm_create;
    const gap = @min(canvas.chrome.px(8), layout.footer.width / 10);
    const primary_width = @min(canvas.chrome.px(if (confirm and !layout.compact) 190 else 132), layout.footer.width * 0.65);
    const cancel_width = @min(canvas.chrome.px(80), @max(0, layout.footer.width - primary_width - gap));
    const primary: Rect = .{ .x = layout.footer.x + layout.footer.width - primary_width, .y = layout.footer.y, .width = primary_width, .height = layout.footer.height };
    try (FormButton{ .bounds = .{ .x = primary.x - gap - cancel_width, .y = primary.y, .width = cancel_width, .height = primary.height }, .text = "Cancel", .action = .{ .prompt = .cancel }, .generation = prompt.generation, .namespace = 2 }).draw(canvas);
    try (FormButton{ .bounds = primary, .text = if (confirm and !layout.compact) "Create folder & context" else "Create context", .action = .{ .prompt = .submit }, .generation = prompt.generation, .namespace = 0, .primary = true, .enabled = prompt.field.len > 0 or prompt.directory.len > 0 }).draw(canvas);
}
