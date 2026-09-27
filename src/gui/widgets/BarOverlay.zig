//! What the bottom bar shows above the panes: the tooltip of the hovered
//! component, or the open panel anchored to the component that opened it.
//! It paints after the rest of the chrome so both float over the panes.
const data = @import("model");
const gfx = @import("gfx");
const std = @import("std");
const Rect = gfx.Rect;
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const BarRow = @import("BarRow.zig");
const inline_nodes = @import("inline_nodes.zig");
const panel_blocks = @import("panel_blocks.zig");
const BlockScope = @import("BlockScope.zig");
const popover_surface = @import("popover_surface.zig");
const BarOverlay = @This();

const gap: f32 = 6;
const margin: f32 = 8;
const radius: f32 = 10;
const tooltip_radius: f32 = 8;
const tooltip_width: f32 = 260;
const tooltip_padding: f32 = 10;
const padding: f32 = 14;
const header_height: f32 = 28;
const status_height: f32 = 18;
const close_side: f32 = 22;
const close_radius: f32 = 5;
const overflow_width: f32 = 300;
const overflow_row: f32 = 26;
const time_format = "%H:%M";
/// The header's mark or icon takes this share of the header's height.
const mark_share: f32 = 0.6;

context: *const Context,
/// The status band; tooltips and panels rise from its top edge.
area: Rect,

/// Example: `try (BarOverlay{ .context = context, .area = bands.status_bar }).draw(canvas);`
pub fn draw(self: BarOverlay, canvas: *Canvas) !void {
    if (self.area.width <= 0 or self.context.projection.status_mode != .normal) {
        return;
    }

    var cpu_buffer: [data.CpuHistory.capacity]u8 = undefined;
    var machine_buffer: [client.Machines.capacity]data.MachineFact = undefined;
    const facts = BarRow.barFacts(self.context, &cpu_buffer, &machine_buffer);
    const panel = &self.context.projection.bar_state.panel;
    switch (panel.target) {
        .none => try self.drawTooltip(canvas, &facts),
        .configured => |index| try self.drawConfigured(canvas, .{ .index = index, .facts = &facts }),
        .overflow => try self.drawOverflow(canvas, &facts),
    }
}

fn drawTooltip(self: BarOverlay, canvas: *Canvas, facts: *const data.BarFacts) !void {
    const hovered = self.context.hovered orelse return;
    if (hovered != .intent or hovered.intent != .bar_component) {
        return;
    }

    const component = hovered.intent.bar_component;
    const content = self.context.projection.bar_state.layout.content(component.position) orelse return;
    if (component.node >= content.node_count or !content.hasTooltip(component.node)) {
        return;
    }

    const anchor = self.context.bands.find(hovered.intent) orelse return;
    const chrome = canvas.chrome;
    const inner = chrome.px(tooltip_padding);
    const width = chrome.px(tooltip_width);
    const scope: BlockScope = .{ .parent = component.node, .tooltip = true };
    const body = try panel_blocks.height(canvas, content, .{ .scope = scope, .width = width - 2 * inner, .facts = facts });
    const bounds = self.place(canvas, .{ .anchor = anchor.area, .width = width, .height = body + 2 * inner });
    try popover_surface.draw(canvas, bounds, chrome.px(tooltip_radius));
    try panel_blocks.draw(canvas, content, .{
        .context = self.context,
        .bounds = inset(bounds, inner),
        .scope = scope,
        .facts = facts,
    });
}

fn drawConfigured(self: BarOverlay, canvas: *Canvas, configured: Configured) !void {
    const projection = self.context.projection;
    const panel = &projection.bar_state.panel;
    const heading = projection.bar_state.layout.panel(configured.index) orelse return;
    const chrome = canvas.chrome;
    const width = chrome.px(@floatFromInt(heading.width));
    const inner = width - 2 * chrome.px(padding);
    const status = statusText(panel);
    var body = try panel_blocks.height(canvas, &panel.content, .{ .scope = .{}, .width = inner, .facts = configured.facts });
    if (status.len != 0) {
        body += chrome.px(status_height) + if (panel.content.isEmpty()) 0 else chrome.px(panel_blocks.block_gap);
    }

    const anchor = if (panel.anchor) |component| self.context.bands.find(.{ .bar_component = component }) else null;
    const bounds = self.place(canvas, .{
        .anchor = if (anchor) |hit| hit.area else self.rightEnd(),
        .width = width,
        .height = self.panelHeight(canvas, body),
    });
    var content_area = try self.drawFrame(canvas, .{
        .bounds = bounds,
        .title = heading.title(),
        .mark = heading.mark,
        .icon = heading.icon,
        .updated = panel.updated,
    });

    if (status.len != 0) {
        _ = try canvas.textAt(.{ .x = content_area.x, .y = content_area.y, .width = content_area.width, .height = chrome.px(status_height) }, .{
            .text = status,
            .color = if (panel.status == .failed) canvas.theme.palette.red else canvas.theme.palette.subtext0,
            .face = .sans,
            .size = .small,
        });
        const used = chrome.px(status_height) + chrome.px(panel_blocks.block_gap);
        content_area.y += used;
        content_area.height = @max(0, content_area.height - used);
    }

    try panel_blocks.draw(canvas, &panel.content, .{
        .context = self.context,
        .bounds = content_area,
        .scope = .{ .interactive = true },
        .facts = configured.facts,
    });
}

const Configured = struct {
    index: u8,
    facts: *const data.BarFacts,
};

fn drawOverflow(self: BarOverlay, canvas: *Canvas, facts: *const data.BarFacts) !void {
    const overflow = self.context.bar_overflow orelse return;
    const chrome = canvas.chrome;
    const rows: f32 = @floatFromInt(overflow.count);
    const anchor = self.context.bands.find(.toggle_bar_overflow);
    const bounds = self.place(canvas, .{
        .anchor = if (anchor) |hit| hit.area else self.rightEnd(),
        .width = chrome.px(overflow_width),
        .height = self.panelHeight(canvas, rows * chrome.px(overflow_row)),
    });
    const content_area = try self.drawFrame(canvas, .{ .bounds = bounds, .title = "More" });
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, content_area);
    const layout = &self.context.projection.bar_state.layout;
    var y = content_area.y;
    for (overflow.slice()) |component| {
        const content = layout.content(component.position) orelse continue;
        const row: Rect = .{ .x = content_area.x, .y = y, .width = content_area.width, .height = chrome.px(overflow_row) };
        y += row.height;
        const node = content.slice()[component.node];
        if (node.isActionable() or content.hasTooltip(component.node)) {
            const intent: client.Intent = .{ .bar_component = component };
            if (self.context.isHovered(.{ .intent = intent })) {
                try canvas.fillRoundedAt(row, .{ .radius = chrome.px(close_radius), .color = canvas.theme.palette.surface0 });
            }

            try self.context.bands.add(.{ .area = row, .action = .{ .intent = intent } });
        }

        try panel_blocks.drawInline(canvas, content, .{ .index = component.node, .bounds = inset(row, chrome.px(inline_nodes.group_padding)), .facts = facts });
    }
}

/// Paints the surface, the header and its close control; returns the body.
fn drawFrame(self: BarOverlay, canvas: *Canvas, frame: Frame) !Rect {
    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    const bounds = frame.bounds;
    if (self.context.bar_panel) |recorded| {
        recorded.* = bounds;
    }

    try popover_surface.draw(canvas, bounds, chrome.px(radius));
    const content = inset(bounds, chrome.px(padding));
    const header: Rect = .{ .x = content.x, .y = content.y, .width = content.width, .height = chrome.px(header_height) };
    var x = header.x;
    if (frame.mark) |mark| {
        try inline_nodes.drawMark(canvas, mark, header);
        x += header.height * mark_share + chrome.px(inline_nodes.child_gap);
    } else if (frame.icon) |icon| {
        const side = header.height * mark_share;
        try canvas.iconAt(.{ .x = x, .y = header.y, .width = side, .height = header.height }, .{ .text = icon.nerdGlyph(), .color = palette.subtext0, .face = .sans, .size = .body });
        x += side + chrome.px(inline_nodes.child_gap);
    }

    const close: Rect = .{
        .x = header.x + header.width - chrome.px(close_side),
        .y = header.y + (header.height - chrome.px(close_side)) / 2,
        .width = chrome.px(close_side),
        .height = chrome.px(close_side),
    };
    const close_hovered = self.context.isHovered(.{ .intent = .close_panel });
    if (close_hovered) {
        try canvas.fillRoundedAt(close, .{ .radius = chrome.px(close_radius), .color = palette.surface1 });
    }

    try canvas.iconAt(close, .{ .text = data.icons.Icon.close.nerdGlyph(), .color = if (close_hovered) palette.text else palette.subtext0, .face = .sans, .size = .small });
    try self.context.bands.add(.{ .area = close, .action = .{ .intent = .close_panel } });

    var right = close.x - chrome.px(inline_nodes.child_gap);
    if (frame.updated) |time| {
        var buffer: [data.bar_clock.max_output_bytes]u8 = undefined;
        const meta: Label = .{ .text = data.bar_clock.format(&buffer, time_format, time), .color = palette.overlay1, .face = .sans, .size = .small };
        const width = try canvas.measure(meta);
        right -= width;
        _ = try canvas.textAt(.{ .x = right, .y = header.y, .width = width, .height = header.height }, meta);
        right -= chrome.px(inline_nodes.child_gap);
    }

    _ = try canvas.textAt(.{ .x = x, .y = header.y, .width = @max(0, right - x), .height = header.height }, .{
        .text = frame.title,
        .color = palette.text,
        .bold = true,
        .face = .sans,
        .size = .body,
    });

    const body_top = header.y + header.height + chrome.px(panel_blocks.block_gap);
    return .{
        .x = content.x,
        .y = body_top,
        .width = content.width,
        .height = @max(0, content.y + content.height - body_top),
    };
}

const Frame = struct {
    bounds: Rect,
    title: []const u8,
    mark: ?data.Mark = null,
    icon: ?data.icons.Icon = null,
    updated: ?data.LocalTime = null,
};

fn panelHeight(self: BarOverlay, canvas: *const Canvas, body: f32) f32 {
    const chrome = canvas.chrome;
    const wanted = 2 * chrome.px(padding) + chrome.px(header_height) + chrome.px(panel_blocks.block_gap) + body;
    const available = self.area.y - @as(f32, @floatFromInt(chrome.top_bar)) - chrome.px(gap) - chrome.px(margin);
    return @max(0, @min(wanted, available));
}

/// Places a box of `size` above `anchor`: right-aligned under the right half
/// of the window, left-aligned under the left half, always inside it.
fn place(self: BarOverlay, canvas: *const Canvas, placement: Placement) Rect {
    const chrome = canvas.chrome;
    const viewport: f32 = @floatFromInt(canvas.viewport[0]);
    const anchor = placement.anchor;
    const right_half = anchor.x + anchor.width / 2 > viewport / 2;
    const wanted = if (right_half) anchor.x + anchor.width - placement.width else anchor.x;
    const edge = chrome.px(margin);
    return .{
        .x = @round(std.math.clamp(wanted, edge, @max(edge, viewport - placement.width - edge))),
        .y = @round(self.area.y - chrome.px(gap) - placement.height),
        .width = @min(placement.width, viewport - 2 * edge),
        .height = placement.height,
    };
}

const Placement = struct {
    anchor: Rect,
    width: f32,
    height: f32,
};

fn rightEnd(self: BarOverlay) Rect {
    return .{ .x = self.area.x + self.area.width, .y = self.area.y, .width = 0, .height = self.area.height };
}

fn statusText(panel: *const data.Panel) []const u8 {
    return switch (panel.status) {
        .loading => if (panel.content.isEmpty()) "Loading…" else "",
        .ready => "",
        .failed => if (panel.content.isEmpty()) "Could not update." else "Could not update; showing the last result.",
    };
}

fn inset(bounds: Rect, by: f32) Rect {
    return .{
        .x = bounds.x + by,
        .y = bounds.y + by,
        .width = @max(0, bounds.width - 2 * by),
        .height = @max(0, bounds.height - 2 * by),
    };
}
