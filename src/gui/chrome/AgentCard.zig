//! One three-row agent card in device pixels: project and age, title, last
//! event with the status glyph and the provider mark. The card paints only;
//! the sidebar owns its position, its hit target and its clipping.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const CardGeometry = @import("CardGeometry.zig");
const TextFit = @import("TextFit.zig");
const Label = @import("Label.zig");
const age_label = @import("age_label.zig");
const status_glyph = @import("status_glyph.zig");
const card_degradation = @import("card_degradation.zig");
const Level = card_degradation.Level;
const AgentCard = @This();

pub const project_glyph = "\u{25a3}";
const elapsed_gap: f32 = 4;

context: *Context,
agent: *const client.Agent,
geometry: CardGeometry,
/// Seconds the status has held, including the time since the snapshot arrived.
age_s: u32,
/// Atlas index of the workspace favicon once a later slice resolves it;
/// `null` draws `project_glyph`.
project_icon: ?u16 = null,

/// Paints the card inside `bounds`. Selected means the focused pane is this
/// agent's pane; hover comes from the chrome's pointer state.
/// Example: `try card.paint(bounds);`
pub fn paint(card: AgentCard, bounds: Rect) !void {
    const canvas = card.context.canvas;
    const palette = canvas.theme.palette;
    const hovered = if (card.context.hovered) |value| std.meta.eql(value, card.action()) else false;
    if (card.selected()) {
        try canvas.fillRoundedAt(bounds, .{ .radius = CardGeometry.radius, .color = palette.surface0 });
        try canvas.ringAt(bounds, .{ .width = 1, .radius = CardGeometry.radius, .color = palette.surface1 });
    } else if (hovered) {
        try canvas.fillRoundedAt(bounds, .{ .radius = CardGeometry.radius, .color = palette.surface1 });
    }

    const first_row = card.geometry.row(bounds, 0);
    const tokens = try card.level(first_row.width);
    try card.paintProject(first_row, tokens);
    try card.paintTitle(card.geometry.row(bounds, 1));
    try card.paintEvent(card.geometry.row(bounds, 2), tokens);
}

/// The action a click on the card performs.
/// Example: `try hits.add(.{ .area = cells, .action = card.action() });`
pub fn action(card: AgentCard) @import("action.zig").Action {
    return .{ .intent = .{ .focus_agent = card.agent.key } };
}

/// Which tokens fit in `width` device pixels of inner card width.
/// Example: `try std.testing.expectEqual(.no_age, try card.level(120));`
pub fn level(card: AgentCard, width: f32) !Level {
    var age_buffer: [age_label.max_bytes]u8 = undefined;
    const canvas = card.context.canvas;
    return card_degradation.resolve(.{
        .available = width,
        .workspace = card.geometry.glyph_width + 4 + try canvas.measure(.{ .text = card.agent.workspaceLabel(), .face = .sans }),
        .age = try canvas.measure(.{ .text = age_label.format(card.age_s, &age_buffer), .face = .sans }),
        .status = try card.statusWidth(),
        .mark = CardGeometry.mark_size + CardGeometry.gap,
        .gap = CardGeometry.gap,
    });
}

/// Whether the focused pane of the active tab is this agent's pane.
/// Example: `if (card.selected()) drawRing();`
pub fn selected(card: AgentCard) bool {
    const model = card.context.projection.model orelse return false;
    if (model.layout.focused() != card.agent.key.pane_id) {
        return false;
    }

    const location = model.location orelse return false;
    return std.meta.eql(location, card.agent.location);
}

fn paintProject(card: AgentCard, row: Rect, tokens: Level) !void {
    const canvas = card.context.canvas;
    const palette = canvas.theme.palette;
    var age_buffer: [age_label.max_bytes]u8 = undefined;
    var age_width: f32 = 0;
    if (tokens.shows(.age)) {
        const age: Label = .{ .text = age_label.format(card.age_s, &age_buffer), .color = palette.subtext0, .face = .sans };
        age_width = try canvas.measure(age);
        _ = try canvas.textAt(.{ .x = row.x + row.width - age_width, .y = row.y, .width = age_width, .height = row.height }, age);
        age_width += CardGeometry.gap;
    }

    // `project_icon` is reserved for the favicon atlas; the generic glyph
    // takes one monospace cell so the label start never depends on shaping.
    const glyph_width = card.geometry.glyph_width;
    _ = try canvas.textAt(.{ .x = row.x, .y = row.y, .width = glyph_width, .height = row.height }, .{ .text = project_glyph, .color = palette.subtext0 });
    const label_x = row.x + glyph_width + 4;
    const label_width = @max(0, row.width - glyph_width - 4 - age_width);
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = label_width };
    const label: Label = .{ .text = card.agent.workspaceLabel(), .color = palette.subtext0, .face = .sans };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(.{ .x = label_x, .y = row.y, .width = label_width, .height = row.height }, fitted);
}

fn paintTitle(card: AgentCard, row: Rect) !void {
    const canvas = card.context.canvas;
    const text = if (card.agent.sessionTitle().len != 0) card.agent.sessionTitle() else card.agent.displayName();
    const label: Label = .{ .text = text, .color = canvas.theme.palette.text, .bold = true, .face = .sans };
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = row.width };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(row, fitted);
}

fn paintEvent(card: AgentCard, row: Rect, tokens: Level) !void {
    const canvas = card.context.canvas;
    const palette = canvas.theme.palette;
    var right = row.x + row.width;
    if (tokens.shows(.mark)) {
        right -= CardGeometry.mark_size;
        try card.paintMark(.{ .x = right, .y = row.y + (row.height - CardGeometry.mark_size) / 2, .width = CardGeometry.mark_size, .height = CardGeometry.mark_size });
        right -= CardGeometry.gap;
    }

    // The elapsed time is its own label so it shares the age's cache entry
    // and only the glyph pulses.
    const ink = status_glyph.color(palette, card.agent.status);
    if (card.agent.status == .working) {
        var age_buffer: [age_label.max_bytes]u8 = undefined;
        const elapsed: Label = .{ .text = age_label.format(card.age_s, &age_buffer), .color = ink, .face = .sans };
        const elapsed_width = try canvas.measure(elapsed);
        right -= elapsed_width;
        _ = try canvas.textAt(.{ .x = right, .y = row.y, .width = elapsed_width, .height = row.height }, elapsed);
        right -= elapsed_gap;
    }

    var status: Label = .{ .text = status_glyph.glyph(card.agent.status, card.agent.blockedReason()), .color = ink, .face = .sans };
    if (card.agent.status == .working) {
        status.alpha = status_glyph.pulse(card.context.projection.sidebar_animation_frame);
    }

    const status_width = try canvas.measure(status);
    right -= status_width;
    _ = try canvas.textAt(.{ .x = right, .y = row.y, .width = status_width, .height = row.height }, status);
    if (!tokens.shows(.event)) {
        return;
    }

    const event_width = @max(0, right - CardGeometry.gap - row.x);
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = event_width };
    const label: Label = .{ .text = card.agent.lastEvent(), .color = palette.overlay1, .face = .sans };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(.{ .x = row.x, .y = row.y, .width = event_width, .height = row.height }, fitted);
}

// The glyph atlas holds alpha only, so the official provider artwork cannot
// enter it yet; a rounded chip with the provider glyph stands in for the mark.
fn paintMark(card: AgentCard, chip: Rect) !void {
    const canvas = card.context.canvas;
    const palette = canvas.theme.palette;
    try canvas.fillRoundedAt(chip, .{ .radius = 4, .color = palette.surface1 });
    const glyph = card.providerGlyph();
    const width: f32 = @floatFromInt(@as(u32, core.measure(glyph)) * canvas.metrics.cell_width);
    const inset = @max(0, (chip.width - width) / 2);
    _ = try canvas.textAt(.{ .x = chip.x + inset, .y = chip.y, .width = chip.width - inset, .height = chip.height }, .{ .text = glyph, .color = palette.subtext0 });
}

fn providerGlyph(card: AgentCard) []const u8 {
    if (card.agent.iconGlyph().len != 0) {
        return card.agent.iconGlyph();
    }

    const icon = client.Icon.forProvider(card.agent.provider) orelse .provider_unknown;
    return icon.unicodeGlyph();
}

fn statusWidth(card: AgentCard) !f32 {
    const canvas = card.context.canvas;
    const glyph = try canvas.measure(.{ .text = status_glyph.glyph(card.agent.status, card.agent.blockedReason()), .face = .sans });
    if (card.agent.status != .working) {
        return glyph;
    }

    var age_buffer: [age_label.max_bytes]u8 = undefined;
    return glyph + elapsed_gap + try canvas.measure(.{ .text = age_label.format(card.age_s, &age_buffer), .face = .sans });
}
