const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Target = @import("interaction/Target.zig");

thread: @import("telar-client").ThreadView,
anchor: Rect,
pane_bounds: Rect,

/// The editor retains native text focus while the completion list owns navigation.
/// Example: `try menu.draw(canvas);`
pub fn draw(menu: @This(), canvas: *Canvas) !void {
    const widgets = canvas.widgets orelse return;
    if (!menu.thread.focused or widgets.composer_menu.selector != null or widgets.preedit.owner != null) {
        return;
    }
    if (widgets.dispatcher.focusedTarget()) |target| {
        if (target.action != .composer or target.action.composer != menu.thread.pane_id) {
            return;
        }
    }

    const state = &widgets.completions;
    state.update(menu.thread);
    if (!state.open or state.pane_id != menu.thread.pane_id) {
        return;
    }

    const padding = canvas.chrome.px(8);
    const partial = menu.thread.transcript != null and menu.thread.transcript.?.skills.truncated;
    const notice_height: f32 = if (partial) canvas.chrome.px(22) else 0;
    const available = @max(0, menu.anchor.y - menu.pane_bounds.y - padding);
    const rows: u8 = @intFromFloat(@min(@as(f32, @floatFromInt(@max(1, @min(state.count, @import("interaction/CompletionState.zig").visible_rows)))), @floor(@max(0, available - padding * 2 - notice_height) / canvas.chrome.px(34))));
    if (rows == 0) {
        return;
    }

    const row_height = canvas.chrome.px(34);
    const height = @as(f32, @floatFromInt(rows)) * row_height + padding * 2 + notice_height;
    const bounds: Rect = .{ .x = menu.anchor.x + padding, .y = menu.anchor.y - height, .width = @max(0, menu.anchor.width - padding * 2), .height = height };
    const first_quad = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first_quad, menu.pane_bounds);
    try (@import("ComposerSurface.zig"){ .bounds = bounds, .radius = canvas.chrome.px(14) }).draw(canvas);
    _ = try widgets.dispatcher.add((Target{ .namespace = 0x4343, .bounds = bounds, .action = .{ .custom = 0x4343 }, .focusable = false }).labelled(if (state.slash) "Commands and skills" else "Skills"));
    const palette = canvas.theme.palette;
    if (partial) {
        try fitted(canvas, .{ .x = bounds.x + padding, .y = bounds.y + padding, .width = @max(0, bounds.width - padding * 2), .height = notice_height }, .{ .text = "Some skills could not be listed", .face = .sans, .size = .small, .color = palette.subtext0 });
    }
    if (state.count == 0) {
        const phase = if (menu.thread.transcript) |snapshot| snapshot.skills.phase else .loading;
        const message: []const u8 = if (state.slash) "No matching commands or skills" else switch (phase) {
            .loading => "Loading skills…",
            .failed => "Skills unavailable",
            .ready => "No matching skills",
        };
        _ = try canvas.textAt(.{ .x = bounds.x + padding, .y = bounds.y + padding + notice_height, .width = @max(0, bounds.width - padding * 2), .height = row_height }, .{ .text = message, .face = .sans, .size = .small, .color = palette.subtext0 });
        return;
    }

    var first = @min(state.first, state.count -| rows);
    if (state.selected < first) {
        first = state.selected;
    } else if (state.selected >= @as(u16, first) + rows) {
        first = state.selected - rows + 1;
    }
    for (0..rows) |offset| {
        const index = first + @as(u8, @intCast(offset));
        if (index >= state.count) {
            break;
        }

        const entry = state.entries[index];
        const row: Rect = .{ .x = bounds.x + padding, .y = bounds.y + padding + notice_height + @as(f32, @floatFromInt(offset)) * row_height, .width = @max(0, bounds.width - padding * 2), .height = row_height };
        if (index == state.selected) {
            try canvas.fillRoundedAt(row, .{ .color = palette.surface1, .radius = canvas.chrome.px(8) });
        }

        var label_buffer: [192]u8 = undefined;
        const skills = if (menu.thread.transcript) |snapshot| &snapshot.skills else null;
        const label = switch (entry) {
            .command => |kind| try std.fmt.bufPrint(&label_buffer, "/{s}", .{@tagName(kind)}),
            .skill => |skill| if (state.slash) try std.fmt.bufPrint(&label_buffer, "/skill:{s}", .{skills.?.entries[skill].name(skills.?)}) else skills.?.entries[skill].label(skills.?),
        };
        const detail = switch (entry) {
            .command => |kind| core.AgentCommand.description(kind),
            .skill => |skill| skills.?.entries[skill].description(skills.?),
        };
        const scope = switch (entry) {
            .command => "",
            .skill => |skill| skills.?.entries[skill].scopeLabel(),
        };
        const badge_width = if (scope.len == 0) 0 else @min(row.width * 0.23, canvas.chrome.px(88));
        const name_width = @min(row.width * 0.48, try canvas.measure(.{ .text = label, .face = .sans, .size = .body }) + padding);
        try fitted(canvas, .{ .x = row.x + padding, .y = row.y, .width = @max(0, name_width - padding), .height = row.height }, .{ .text = label, .face = .sans, .size = .body, .color = palette.text });
        try fitted(canvas, .{ .x = row.x + name_width + padding, .y = row.y, .width = @max(0, row.width - name_width - badge_width - padding * 3), .height = row.height }, .{ .text = detail, .face = .sans, .size = .small, .color = palette.subtext0 });
        try fitted(canvas, .{ .x = row.x + row.width - badge_width, .y = row.y, .width = badge_width, .height = row.height }, .{ .text = scope, .face = .sans, .size = .small, .color = palette.subtext0 });
        _ = try widgets.dispatcher.add((Target{ .id = .{ .generation = menu.thread.attachment_generation }, .bounds = row, .action = .{ .composer_completion = .{ .pane_id = menu.thread.pane_id, .generation = state.generation, .index = index } }, .focusable = false, .role = 4 }).labelled(label));
    }
}

fn fitted(canvas: *Canvas, bounds: Rect, label: @import("Label.zig")) !void {
    var buffer: [@import("TextFit.zig").max_bytes]u8 = undefined;
    var value = label;
    value.text = try (@import("TextFit.zig"){ .canvas = canvas, .width = bounds.width }).fit(label, &buffer);
    _ = try canvas.textAt(bounds, value);
}
