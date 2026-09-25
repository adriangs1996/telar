//! Borders, headers, attention rings and the unfocused dim of every visible
//! pane. Borders are the TUI frame in pixels: a one-pixel rounded outline,
//! `overlay0`, `accent` when focused, drawn only when the layout has
//! borders, so a single pane shows nothing but the sidebar edge. The ring
//! is two logical pixels inside the border in the status colour, only for a
//! pane whose agent is blocked or failed and only while it is not focused;
//! it fades in through `RingFades`. Unfocused panes get one quad of the
//! terminal background at 0.15 over their content. A fullscreen pane keeps
//! its top row plain and carries the `FullscreenStrip` on its bottom row.
const cellgrid = @import("cellgrid");
const data = @import("model");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const PaneHeader = @import("PaneHeader.zig");
const FullscreenStrip = @import("FullscreenStrip.zig");
const RingFades = @import("RingFades.zig");
const RingSpec = @import("RingSpec.zig");
const attention = @import("attention.zig");
const Canvas = @import("Canvas.zig");
const PaneDecorations = @This();

pub const dim_alpha: f32 = 0.15;
pub const ring_width: f32 = 2;
/// Corner radius of the pane frame in logical pixels, the pixel twin of the
/// TUI's rounded box-drawing corners.
pub const frame_radius: f32 = 6;

context: *const Context,
rings: *RingFades,

/// Uses the same immutable pane geometry as terminal painting and input routing.
/// Example: `try decorations.draw(canvas);`
pub fn draw(self: PaneDecorations, canvas: *Canvas) !void {
    const context = self.context;
    const projection = context.projection;
    const tab = projection.tab orelse return;
    const model = projection.model;
    const location = model.tabs.location[tab];
    self.rings.begin();
    defer self.rings.end();
    if (!model.tabs.layout[tab].hasBorders()) {
        return;
    }

    const layout = projection.layout.?;
    for (layout.views()) |view| {
        const pane = model.panes.findInConst(location.tab_id, view.pane_id) orelse continue;
        const agent = attention.paneAgent(projection, location, view.pane_id);
        try self.border(canvas, view);
        if (model.tabs.layout[tab].isFullscreen()) {
            const strip: FullscreenStrip = .{ .context = context, .tab = tab, .area = canvas.rect(view.outer.row(view.outer.h -| 1)) };
            try strip.draw(canvas);
        } else {
            const header: PaneHeader = .{ .context = context, .pane = pane, .agent = agent, .index = view.display_index, .area = canvas.rect(view.outer.row(0)) };
            try header.draw(canvas);
        }

        if (!view.focused) {
            try canvas.dimAt(canvas.rect(view.content), dim_alpha);
            if (agent) |value| {
                if (attention.needsInput(value.status)) {
                    try self.ring(canvas, .{ .view = view, .status = value.status, .key = .{ .pane_id = pane.id, .pane_generation = pane.attachment_generation } });
                }
            }
        }
    }
}

fn ring(self: PaneDecorations, canvas: *Canvas, spec: RingSpec) !void {
    const outer = self.frameRect(canvas, spec.view);
    const inset: Rect = .{ .x = outer.x + 1, .y = outer.y + 1, .width = @max(0, outer.width - 2), .height = @max(0, outer.height - 2) };
    try canvas.ringAt(inset, .{
        .width = canvas.chrome.px(ring_width),
        .radius = @max(0, canvas.chrome.px(frame_radius) - 1),
        .color = attention.statusColor(canvas.theme.palette, spec.status),
        .alpha = if (canvas.animation) |clock| self.rings.alpha(spec.key, clock) else 1,
    });
}

fn border(self: PaneDecorations, canvas: *Canvas, view: data.LayoutView) !void {
    const context = self.context;
    const outer = view.outer;
    const content = view.content;
    const bands = [_]cellgrid.Rect{
        .{ .x = outer.x, .y = outer.y, .w = outer.w, .h = content.y -| outer.y },
        .{ .x = outer.x, .y = content.y + content.h, .w = outer.w, .h = (outer.y + outer.h) -| (content.y + content.h) },
        .{ .x = outer.x, .y = content.y, .w = content.x -| outer.x, .h = content.h },
        .{ .x = content.x + content.w, .y = content.y, .w = (outer.x + outer.w) -| (content.x + content.w), .h = content.h },
    };
    for (bands) |band| {
        try canvas.panel(band);
        try context.hits.add(.{ .area = band, .action = .{ .intent = .{ .focus_pane = view.pane_id } } });
    }

    const original = canvas.rect(outer);
    const frame = self.frameRect(canvas, view);
    const extensions = [_]Rect{
        .{ .x = original.x + original.width, .y = original.y, .width = frame.width - original.width, .height = original.height },
        .{ .x = original.x, .y = original.y + original.height, .width = original.width, .height = frame.height - original.height },
    };
    for (extensions) |extension| {
        try canvas.panelAt(extension);
        try context.bands.add(.{ .area = extension, .action = .{ .intent = .{ .focus_pane = view.pane_id } } });
    }

    try canvas.ringAt(frame, .{
        .width = 1,
        .radius = canvas.chrome.px(frame_radius),
        .color = if (view.focused) canvas.theme.palette.accent else canvas.theme.palette.overlay0,
    });
}

// The grid reserves rectangular cells for gutters. Extend the trailing frame
// into that reservation so both axes leave the smaller pixel gap, without
// moving terminal cells or their input coordinates.
fn frameRect(self: PaneDecorations, canvas: *const Canvas, view: data.LayoutView) Rect {
    var frame = canvas.rect(view.outer);
    const projection = self.context.projection;
    const layout = &projection.model.tabs.layout[projection.tab.?];
    const gap = layout.metrics.gutter(layout.pane_gaps);
    const cell = canvas.metrics;
    const minimum = @min(cell.cell_width, cell.cell_height);
    const area = self.context.projection.geometry.area;
    if (view.outer.x + view.outer.w < area.x + area.w) {
        frame.width += @floatFromInt(@as(u32, gap) * (cell.cell_width - minimum));
    }

    if (view.outer.y + view.outer.h < area.y + area.h) {
        frame.height += @floatFromInt(@as(u32, gap) * (cell.cell_height - minimum));
    }

    return frame;
}
