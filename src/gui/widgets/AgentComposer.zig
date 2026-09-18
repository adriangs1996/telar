const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Composer = @This();

bounds: Rect,
pane_bounds: Rect,
thread: client.ThreadView,

/// Paints a native composer with the provider's real selectable options.
/// Example: `try composer.draw(canvas);`
pub fn draw(composer: Composer, canvas: *Canvas) !void {
    var layout = @import("ComposerLayout.zig").resolve(canvas, composer.bounds);
    try composer.drawContext(canvas, layout.context);
    try (@import("ComposerSurface.zig"){ .bounds = layout.card, .radius = canvas.chrome.px(22), .focused = composer.thread.focused }).draw(canvas);
    try composer.drawImages(canvas, &layout.editor);
    const selection: [2]u32 = if (composer.thread.composer_field) |field| .{ @intCast(field.anchor), @intCast(field.head) } else .{ 0, 0 };
    try (@import("TextField.zig"){ .bounds = layout.editor, .text = composer.thread.composer, .selection = selection, .action = .{ .composer = composer.thread.pane_id }, .generation = composer.thread.attachment_generation, .focused = composer.thread.focused, .label = "Message to agent", .placeholder = "Ask for changes or send a follow-up…", .layer = 0, .multiline = true, .appearance = .embedded, .face = .sans, .font_pixels = @intFromFloat(@round(canvas.chrome.px(16))) }).draw(canvas);
    var next_x = layout.selectors[0].x;
    const single_row = layout.selectors[0].y == layout.selectors[2].y;
    for ([_]@FieldType(@import("interaction/ComposerSelector.zig"), "kind"){ .model, .effort, .access }, layout.selectors) |kind, area| {
        const options: @import("ComposerOptions.zig") = .{ .thread = composer.thread, .kind = kind };
        const count = options.count();
        const label = if (count > 0) options.label(options.selected()) else switch (kind) {
            .recent => unreachable,
            .model => "Loading models…",
            .effort => "Reasoning",
            .access => "Permissions",
        };
        var bounds = area;
        if (single_row) {
            bounds.x = next_x;
            bounds.width = @min(area.width, try canvas.measure(.{ .text = label, .face = .sans, .size = .body }) + canvas.chrome.px(if (kind == .effort) @as(f32, 34) else 60));
            bounds.width = @min(bounds.width, @max(0, layout.send.x - canvas.chrome.px(10) - bounds.x));
            if (kind != .model) {
                try canvas.ringAt(.{ .x = bounds.x - canvas.chrome.px(10), .y = bounds.y + bounds.height * 0.3, .width = canvas.chrome.px(0.7), .height = bounds.height * 0.4 }, .{ .color = canvas.theme.palette.overlay0, .width = canvas.chrome.px(0.7), .alpha = 0.5 });
            }

            next_x = bounds.x + bounds.width + canvas.chrome.px(20);
        }

        try (@import("ComposerTrigger.zig"){
            .bounds = bounds,
            .selector = .{ .pane_id = composer.thread.pane_id, .kind = kind, .catalog_revision = composer.thread.catalog_revision, .options_revision = composer.thread.options_revision },
            .generation = composer.thread.attachment_generation,
            .label = label,
            .enabled = count > 0,
        }).draw(canvas);
    }

    try composer.drawSend(canvas, layout.send);
    try (@import("CompletionMenu.zig"){ .thread = composer.thread, .anchor = layout.card, .pane_bounds = composer.pane_bounds }).draw(canvas);
    try (@import("ComposerMenu.zig"){ .thread = composer.thread, .pane_bounds = composer.pane_bounds }).draw(canvas);
}

fn drawImages(composer: Composer, canvas: *Canvas, editor: *Rect) !void {
    const images = composer.thread.composer_images orelse return;
    if (images.count == 0) {
        return;
    }

    const height = @min(canvas.chrome.px(72), editor.height * 0.6);
    const gap = @min(canvas.chrome.px(8), editor.width / 20);
    const width = @min(height, @max(0, (editor.width - gap * @as(f32, @floatFromInt(images.count - 1))) / @as(f32, @floatFromInt(images.count))));
    for (0..images.count) |index| {
        try (@import("ComposerImage.zig"){
            .bounds = .{ .x = editor.x + @as(f32, @floatFromInt(index)) * (width + gap), .y = editor.y, .width = width, .height = height },
            .thread = composer.thread,
            .index = @intCast(index),
        }).draw(canvas);
    }

    editor.y += height + gap;
    editor.height = @max(0, editor.height - height - gap);
}

fn drawSend(composer: Composer, canvas: *Canvas, bounds: Rect) !void {
    const status = if (composer.thread.transcript) |snapshot| snapshot.status else .starting;
    const working = status == .working or status == .blocked;
    const pasting = if (canvas.widgets) |state| state.pastingImage(composer.thread.pane_id) else false;
    const enabled = working or !pasting and status == .ready and (composer.thread.composer.len != 0 or (if (composer.thread.composer_images) |images| images.count != 0 else false));
    const palette = canvas.theme.palette;
    try canvas.fillRoundedAt(bounds, .{ .color = if (enabled) palette.accent else palette.surface1, .radius = bounds.height / 2 });
    const icon: Rect = .{ .x = bounds.x + bounds.width * 0.22, .y = bounds.y + bounds.height * 0.22, .width = bounds.width * 0.56, .height = bounds.height * 0.56 };
    if (working) {
        try canvas.fillRoundedAt(.{ .x = bounds.x + bounds.width * 0.34, .y = bounds.y + bounds.height * 0.34, .width = bounds.width * 0.32, .height = bounds.height * 0.32 }, .{ .color = palette.surface_dim, .radius = canvas.chrome.px(2) });
    } else if (pasting) {
        _ = try canvas.textAt(bounds, .{ .text = "…", .face = .sans, .size = .body, .color = palette.subtext0 });
    } else {
        try canvas.iconAt(icon, .{ .text = "\u{f062}", .color = if (enabled) palette.surface_dim else palette.subtext0, .size = .body });
    }

    if (canvas.widgets) |state| {
        _ = try state.dispatcher.add((@import("interaction/Target.zig"){ .id = .{ .generation = composer.thread.attachment_generation }, .bounds = bounds, .action = .{ .agent_control = .{ .pane_id = composer.thread.pane_id, .kind = if (working) .interrupt else .submit } }, .enabled = enabled }).labelled(if (working) "Stop agent" else if (pasting) "Pasting image" else "Send message"));
    }
}

fn drawContext(composer: Composer, canvas: *Canvas, bounds: Rect) !void {
    if (composer.thread.cwd.len == 0 and composer.thread.branch.len == 0) {
        return;
    }

    const palette = canvas.theme.palette;
    try canvas.fillRoundedAt(bounds, .{ .color = palette.panel_bg, .radius = canvas.chrome.px(15) });
    try canvas.ringAt(bounds, .{ .color = palette.overlay0, .alpha = 0.35, .width = canvas.chrome.px(0.6), .radius = canvas.chrome.px(15) });
    const inset = @min(canvas.chrome.px(16), bounds.width / 12);
    const row: Rect = .{ .x = bounds.x + inset, .y = bounds.y + canvas.chrome.px(16), .width = @max(0, bounds.width - 2 * inset), .height = @max(0, bounds.height - canvas.chrome.px(16)) };
    const branch_width = if (composer.thread.branch.len > 0) @min(row.width * 0.4, try canvas.measure(.{ .text = composer.thread.branch, .face = .sans, .size = .small }) + canvas.chrome.px(28)) else 0;
    const folder_width = @max(0, row.width - branch_width - canvas.chrome.px(8));
    const icon_width = @min(canvas.chrome.px(22), folder_width / 4);
    try canvas.iconAt(.{ .x = row.x, .y = row.y, .width = icon_width, .height = row.height }, .{ .text = @import("AgentCard.zig").project_glyph, .color = palette.subtext0, .size = .small });
    var storage: [@import("TextFit.zig").max_bytes]u8 = undefined;
    const label: @import("Label.zig") = .{ .text = if (composer.thread.cwd.len > 0) std.fs.path.basename(composer.thread.cwd) else "", .face = .sans, .size = .small, .color = palette.subtext0 };
    const fitted = try (@import("TextFit.zig"){ .canvas = canvas, .width = @max(0, folder_width - icon_width) }).fit(label, &storage);
    _ = try canvas.textAt(.{ .x = row.x + icon_width, .y = row.y, .width = @max(0, folder_width - icon_width), .height = row.height }, .{ .text = fitted, .face = .sans, .size = .small, .color = palette.subtext0 });
    if (branch_width > 0) {
        const x = row.x + row.width - branch_width;
        try canvas.iconAt(.{ .x = x, .y = row.y, .width = canvas.chrome.px(22), .height = row.height }, .{ .text = client.Icon.app_git.nerdGlyph(), .color = palette.subtext0, .size = .small });
        const branch = try (@import("TextFit.zig"){ .canvas = canvas, .width = @max(0, branch_width - canvas.chrome.px(22)) }).fit(.{ .text = composer.thread.branch, .face = .sans, .size = .small }, &storage);
        _ = try canvas.textAt(.{ .x = x + canvas.chrome.px(22), .y = row.y, .width = @max(0, branch_width - canvas.chrome.px(22)), .height = row.height }, .{ .text = branch, .face = .sans, .size = .small, .color = palette.subtext0 });
    }
}
