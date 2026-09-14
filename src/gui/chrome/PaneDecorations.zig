//! Borders, headers, attention rings and the unfocused dim of every visible
//! pane. Borders are the TUI frame in pixels: a one-pixel rounded outline,
//! `overlay0`, `accent` when focused, drawn only when the layout has
//! borders, so a single pane shows nothing but the sidebar edge. The ring
//! is two logical pixels inside the border in the status colour, only for a
//! pane whose agent is blocked or failed and only while it is not focused;
//! it fades in through `RingFades`. Unfocused panes get one quad of the
//! terminal background at 0.15 over their content.
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const PaneHeader = @import("PaneHeader.zig");
const PaneProgress = @import("PaneProgress.zig");
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

context: *Context,
rings: *RingFades,

/// Uses the same immutable pane geometry as terminal painting and input routing.
/// Example: `try decorations.draw(canvas);`
pub fn draw(decorations: PaneDecorations, canvas: *Canvas) !void {
    var context = decorations.context.*;
    context.canvas = canvas;
    var prepared = decorations;
    prepared.context = &context;
    try prepared.paint();
}

fn paint(decorations: PaneDecorations) !void {
    const context = decorations.context;
    const projection = context.projection;
    const model = projection.model orelse return;
    decorations.rings.begin();
    defer decorations.rings.end();
    if (!model.layout.hasBorders()) {
        return;
    }

    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    for (layout.views()) |view| {
        const pane = model.findConst(view.pane_id) orelse continue;
        const agent = if (model.location) |location| attention.paneAgent(projection, location, view.pane_id) else null;
        try decorations.border(view);
        const title = view.outer.row(0);
        if (model.layout.isFullscreen()) {
            const strip: FullscreenStrip = .{ .context = context, .model = model };
            try strip.paint(title);
        } else {
            const header: PaneHeader = .{ .context = context, .pane = pane, .agent = agent, .index = view.display_index };
            try header.paint(context.canvas.rect(title));
        }

        const progress: PaneProgress = .{ .context = context, .pane = pane };
        try progress.paint(view.outer);
        if (!view.focused) {
            try context.canvas.dimAt(context.canvas.rect(view.content), dim_alpha);
            if (agent) |value| {
                if (attention.needsInput(value.status)) {
                    try decorations.ring(.{ .view = view, .status = value.status, .key = .{ .pane_id = pane.id, .pane_generation = pane.attachment_generation } });
                }
            }
        }
    }
}

fn ring(decorations: PaneDecorations, spec: RingSpec) !void {
    const canvas = decorations.context.canvas;
    const outer = canvas.rect(spec.view.outer);
    const inset: Rect = .{ .x = outer.x + 1, .y = outer.y + 1, .width = @max(0, outer.width - 2), .height = @max(0, outer.height - 2) };
    try canvas.ringAt(inset, .{
        .width = canvas.chrome.px(ring_width),
        .radius = @max(0, canvas.chrome.px(frame_radius) - 1),
        .color = attention.statusColor(canvas.theme.palette, spec.status),
        .alpha = if (canvas.animation) |clock| decorations.rings.alpha(spec.key, clock) else 1,
    });
}

fn border(decorations: PaneDecorations, view: client.LayoutView) !void {
    const context = decorations.context;
    const outer = view.outer;
    const content = view.content;
    const bands = [_]core.Rect{
        .{ .x = outer.x, .y = outer.y, .w = outer.w, .h = content.y -| outer.y },
        .{ .x = outer.x, .y = content.y + content.h, .w = outer.w, .h = (outer.y + outer.h) -| (content.y + content.h) },
        .{ .x = outer.x, .y = content.y, .w = content.x -| outer.x, .h = content.h },
        .{ .x = content.x + content.w, .y = content.y, .w = (outer.x + outer.w) -| (content.x + content.w), .h = content.h },
    };
    for (bands) |band| {
        try context.canvas.panel(band);
        try context.hits.add(.{ .area = band, .action = .{ .intent = .{ .focus_pane = view.pane_id } } });
    }

    const canvas = context.canvas;
    try canvas.ringAt(canvas.rect(outer), .{
        .width = 1,
        .radius = canvas.chrome.px(frame_radius),
        .color = if (view.focused) canvas.theme.palette.accent else canvas.theme.palette.overlay0,
    });
}
