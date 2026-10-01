//! The collapsed sidebar: one mark per workspace in runtime order, spaced so
//! each breathes: its favicon or initial tile and its attention dot, with no
//! surface until hover. The selected one is filled and carries an accent pill
//! on the rail's edge. Names wait in `RailTooltip`. Overflow
//! counters select the nearest hidden workspace and keep the attention of the
//! ones they hide.
const cellgrid = @import("cellgrid");
const std = @import("std");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const attention = @import("attention.zig");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const PixelButton = @import("PixelButton.zig");
const WorkspaceMark = @import("WorkspaceMark.zig");
const WorkspaceWindow = @import("WorkspaceWindow.zig");
const SpriteSize = @import("../image/SpriteSize.zig").SpriteSize;
const WorkspaceRail = @This();

/// Logical side of one workspace mark's control.
pub const button: f32 = 36;
/// Logical gap between two workspace controls.
pub const button_gap: f32 = 10;
const inset: f32 = 12;
const radius: f32 = 10;
const accent_width: f32 = 3;
const accent_height: f32 = 20;
const dot_side: f32 = 7;
const dot_ring: f32 = 2;
const dot_inset: f32 = 4;
const counter_height: f32 = 20;

context: *const Context,
area: Rect,

/// Paints the rail and registers one target per visible mark.
/// Example: `try (WorkspaceRail{ .context = context, .area = bands.sidebar }).draw(canvas);`
pub fn draw(self: WorkspaceRail, canvas: *Canvas) !void {
    const area = self.area;
    if (area.width <= 1 or area.height <= 0) {
        return;
    }

    const chrome = canvas.chrome;
    try canvas.panelAt(.{ .x = area.x, .y = area.y, .width = area.width - 1, .height = area.height });
    try canvas.fillAt(.{ .x = area.x + area.width - 1, .y = area.y, .width = 1, .height = area.height }, canvas.theme.palette.surface1);

    const side = @min(chrome.px(button), area.width - 1);
    const left = area.x + @floor((area.width - 1 - side) / 2);
    const top = area.y + chrome.px(inset);
    const list: Rect = .{ .x = left, .y = top, .width = side, .height = @max(0, area.y + area.height - chrome.px(inset) - top) };
    try self.drawList(canvas, list);
}

fn drawList(self: WorkspaceRail, canvas: *Canvas, list: Rect) !void {
    const snapshot = self.context.projection.workspaces;
    if (snapshot.project_count == 0 or list.height <= 0) {
        return;
    }

    const chrome = canvas.chrome;
    const gap = chrome.px(button_gap);
    const pitch = list.width + gap;
    const counter = chrome.px(counter_height);
    var capacity: usize = @intFromFloat(@max(0, @floor((list.height + gap) / pitch)));
    const counters = capacity < snapshot.project_count and list.height >= list.width + 2 * (counter + gap);
    if (counters) {
        capacity = @intFromFloat(@max(0, @floor((list.height - 2 * (counter + gap) + gap) / pitch)));
    }

    // A worktree's workspace keeps its project in view; only projects have marks.
    const current = if (self.context.workspaceId()) |id| snapshot.indexOf(snapshot.projectOf(id)) orelse 0 else 0;
    const window = WorkspaceWindow.centered(snapshot.project_count, current, @max(1, capacity));
    var y = list.y;
    if (counters) {
        if (window.previous()) |index| {
            try self.drawCounter(canvas, .{ .x = list.x, .y = y, .width = list.width, .height = counter }, .{ 0, index + 1 });
        }

        y += counter + gap;
    }

    for (window.first..window.first + window.count) |index| {
        if (y + list.width > list.y + list.height) {
            break;
        }

        try self.drawMark(canvas, .{ .x = list.x, .y = y, .width = list.width, .height = list.width }, index);
        y += pitch;
    }

    if (counters) {
        if (window.next()) |index| {
            try self.drawCounter(canvas, .{ .x = list.x, .y = y, .width = list.width, .height = counter }, .{ index, snapshot.project_count });
        }
    }
}

fn drawMark(self: WorkspaceRail, canvas: *Canvas, bounds: Rect, index: usize) !void {
    const context = self.context;
    const projection = context.projection;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const id = projection.workspaces.workspaceAt(index);
    const selected = context.workspaceId() == id;
    const hovered = context.isHovered(.{ .intent = .{ .select_workspace = id } });
    if (selected or hovered) {
        try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(radius), .color = if (selected) palette.surface1 else palette.surface0 });
    }

    if (selected) {
        // A pill whose left half sits past the window edge, so only its
        // rounded right end shows against the rail.
        const bar_height = @min(chrome.px(accent_height), bounds.height);
        const width = chrome.px(accent_width);
        const bar: Rect = .{ .x = self.area.x - width, .y = bounds.y + (bounds.height - bar_height) / 2, .width = 2 * width, .height = bar_height };
        const first = canvas.quads.items().len;
        try canvas.fillRoundedAt(bar, .{ .radius = width, .color = palette.accent });
        canvas.quads.clipFrom(first, self.area);
    }

    const side = @min(@round(chrome.px(SpriteSize.large.logical())), bounds.width);
    const mark: WorkspaceMark = .{
        .context = context,
        .workspace = id,
        .bounds = .{ .x = bounds.x + (bounds.width - side) / 2, .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side },
        .ink = if (selected or hovered) palette.text else palette.subtext0,
        .emphasized = selected or hovered,
        .sprite_size = .large,
        .size = .body,
        .name = projection.workspaces.nameAt(index),
    };
    try mark.draw(canvas);

    if (attention.workspaceDot(projection, palette, id)) |color| {
        try drawDot(canvas, bounds, color);
    }

    context.bands.add(.{
        .area = bounds,
        .action = .{ .intent = .{ .select_workspace = id } },
    });
}

fn drawCounter(self: WorkspaceRail, canvas: *Canvas, bounds: Rect, range: [2]usize) !void {
    const projection = self.context.projection;
    const nearest = if (range[0] == 0) range[1] - 1 else range[0];
    var storage: [8]u8 = undefined;
    const counter: PixelButton = .{
        .context = self.context,
        .area = bounds,
        .intent = .{ .select_workspace = projection.workspaces.workspaceAt(nearest) },
        .text = std.fmt.bufPrint(&storage, "+{d}", .{range[1] - range[0]}) catch unreachable,
        .alignment = .center,
        .background = false,
        .hover_fill = true,
        .size = .small,
        .radius = canvas.chrome.px(6),
    };
    try counter.draw(canvas);

    if (attention.listRangeDot(projection, canvas.theme.palette, range)) |color| {
        try drawDot(canvas, bounds, color);
    }
}

// The dot sits in the control's top-right corner inside a ring of the rail's
// own background, so it reads over the favicon and over a hovered surface.
fn drawDot(canvas: *Canvas, bounds: Rect, color: cellgrid.Color) !void {
    const chrome = canvas.chrome;
    const side = chrome.px(dot_side);
    const ring = chrome.px(dot_ring);
    const dot: Rect = .{ .x = bounds.x + bounds.width - chrome.px(dot_inset) - side, .y = bounds.y + chrome.px(dot_inset), .width = side, .height = side };
    const halo: Rect = .{ .x = dot.x - ring, .y = dot.y - ring, .width = side + 2 * ring, .height = side + 2 * ring };
    try canvas.fillRoundedAt(halo, .{ .radius = halo.width / 2, .color = canvas.covering(canvas.theme.palette.panel_bg) });
    try canvas.fillRoundedAt(dot, .{ .radius = side / 2, .color = color });
}
