//! One three-row agent card: project and status, a regular-weight title,
//! then the live event while working or the workspace branch at rest. The card paints only;
//! the sidebar owns its position, its hit target and its clipping.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const CardGeometry = @import("CardGeometry.zig");
const TextFit = @import("TextFit.zig");
const Label = @import("Label.zig");
const age_label = @import("age_label.zig");
const status_glyph = @import("status_glyph.zig");
const Sprite = @import("../image/Sprite.zig");
const AgentCard = @This();

pub const project_glyph = "\u{f07b}";
pub const provider_alpha: f32 = 0.6;

context: *const Context,
bounds: Rect,
agent: *const client.Agent,
geometry: CardGeometry,
/// Seconds the status has held, including the time since the snapshot arrived.
age_s: u32,
/// The workspace favicon in the sprite page once the favicon worker has
/// resolved it; `null` draws `project_glyph`.
project_icon: ?Sprite = null,

/// Draws the card at its composed bounds. Selection follows the focused pane;
/// hover comes from the context. Example: `try card.draw(canvas);`
pub fn draw(card: AgentCard, canvas: *Canvas) !void {
    const bounds = card.bounds;
    const palette = canvas.theme.palette;
    const hovered = if (card.context.hovered) |value| std.meta.eql(value, card.action()) else false;
    if (card.selected()) {
        try canvas.fillRoundedAt(bounds, .{ .radius = card.geometry.px(CardGeometry.radius), .color = palette.surface0 });
        try canvas.ringAt(bounds, .{ .width = 1, .radius = card.geometry.px(CardGeometry.radius), .color = palette.surface1 });
    } else if (hovered) {
        try canvas.fillRoundedAt(bounds, .{ .radius = card.geometry.px(CardGeometry.radius), .color = palette.surface1 });
    }

    const first_row = card.geometry.row(bounds, 0);
    try card.drawProject(canvas, first_row);
    try card.drawTitle(canvas, card.geometry.row(bounds, 1));
    try card.drawDetail(canvas, card.geometry.row(bounds, 2));
}

/// The action a click on the card performs.
/// Example: `try hits.add(.{ .area = cells, .action = card.action() });`
pub fn action(card: AgentCard) @import("action.zig").Action {
    return .{ .intent = .{ .focus_agent = card.agent.key } };
}

/// Borrows the live event or the branch of this agent's own workspace.
/// Missing Git observations and worktree-only locations have no branch fallback.
/// Example: `const detail = card.detailText();`
pub fn detailText(card: AgentCard) []const u8 {
    if (card.agent.status == .working) {
        return card.agent.lastEvent();
    }

    const workspace = switch (card.agent.location.workspace) {
        .workspace => |id| id,
        .worktree => return "",
    };
    const workspaces = card.context.projection.workspaces;
    const index = workspaces.indexOf(workspace) orelse return "";
    return workspaces.branchAt(index);
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

fn drawProject(card: AgentCard, canvas: *Canvas, row: Rect) !void {
    const palette = canvas.theme.palette;
    const gap = card.geometry.px(4);
    const slot = card.projectSlot(canvas);
    const reserved = @min(row.width / 2, slot + gap + card.geometry.px(24));
    const status_width = try card.drawStatus(canvas, .{ .x = row.x + reserved, .y = row.y, .width = row.width - reserved, .height = row.height });
    const project_width = @max(0, row.width - status_width - card.geometry.px(CardGeometry.gap));
    if (project_width < slot) {
        return;
    }

    if (card.project_icon) |icon| {
        const side = @min(card.markSide(canvas), row.height);
        try canvas.spriteAt(.{ .x = row.x + (slot - side) / 2, .y = row.y + (row.height - side) / 2, .width = side, .height = side }, icon);
    } else {
        _ = try canvas.textAt(.{ .x = row.x, .y = row.y, .width = slot, .height = row.height }, .{ .text = project_glyph, .color = palette.subtext0, .face = .sans, .size = .small });
    }

    const label_x = row.x + slot + gap;
    const label_width = @max(0, project_width - slot - gap);
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = label_width };
    const label: Label = .{ .text = card.agent.workspaceLabel(), .color = palette.subtext0, .face = .sans, .size = .small };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(.{ .x = label_x, .y = row.y, .width = label_width, .height = row.height }, fitted);
}

// The top-right slot drops duration, then the word, before clipping its
// glyph. Only the glyph pulses; the state and the clock remain readable.
fn drawStatus(card: AgentCard, canvas: *Canvas, row: Rect) !f32 {
    const state = card.agent.status;
    const ink = status_glyph.color(canvas.theme.palette, state);
    const gap = card.geometry.px(4);
    const word = status_glyph.label(state, card.agent.blockedReason());
    var age_buffer: [age_label.max_bytes]u8 = undefined;
    var text_buffer: [32]u8 = undefined;
    const text = switch (state) {
        .working => std.fmt.bufPrint(&text_buffer, "{s} {s}", .{ word, age_label.duration(card.age_s, &age_buffer) }) catch unreachable,
        .ready => age_label.format(card.age_s, &age_buffer),
        else => word,
    };
    var glyph: Label = .{ .text = if (state == .ready) "" else status_glyph.glyph(state, card.agent.blockedReason()), .color = ink, .face = .sans, .size = .small };
    const glyph_width = if (glyph.text.len == 0) 0 else try canvas.measure(glyph);
    const glyph_space = if (glyph_width == 0) 0 else glyph_width + gap;
    var label: Label = .{ .text = text, .color = ink, .face = .sans, .size = .small };
    var label_width = try canvas.measure(label);
    if (glyph_space + label_width > row.width) {
        label.text = word;
        label_width = try canvas.measure(label);
    }

    if (glyph_space + label_width > row.width) {
        label.text = "";
        label_width = 0;
    }

    const used = @min(row.width, glyph_width + label_width + if (glyph_width > 0 and label_width > 0) gap else @as(f32, 0));
    const left = row.x + row.width - used;
    if (state == .working) {
        const frame: u8 = if (canvas.animation) |clock| @truncate(clock.step(120 * std.time.ns_per_ms)) else card.context.projection.sidebar_animation_frame;
        glyph.alpha = status_glyph.pulse(frame);
    }

    if (glyph_width > 0) {
        _ = try canvas.textAt(.{ .x = left, .y = row.y, .width = @min(used, glyph_width), .height = row.height }, glyph);
    }

    if (label_width > 0) {
        _ = try canvas.textAt(.{ .x = row.x + row.width - label_width, .y = row.y, .width = label_width, .height = row.height }, label);
    }

    return used;
}

fn drawTitle(card: AgentCard, canvas: *Canvas, row: Rect) !void {
    const text = if (card.agent.sessionTitle().len != 0) card.agent.sessionTitle() else card.agent.displayName();
    const label: Label = .{ .text = text, .color = canvas.theme.palette.text, .face = .sans, .size = .title };
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = row.width };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(row, fitted);
}

fn drawDetail(card: AgentCard, canvas: *Canvas, row: Rect) !void {
    const side = card.markSide(canvas);
    var width = row.width;
    if (side <= row.width) {
        try card.drawMark(canvas, .{ .x = row.x + row.width - side, .y = row.y + (row.height - side) / 2, .width = side, .height = side });
        width = @max(0, width - side - card.geometry.px(CardGeometry.gap));
    }

    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = width };
    const label: Label = .{ .text = card.detailText(), .color = canvas.theme.palette.overlay1, .face = .sans, .size = .small };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(.{ .x = row.x, .y = row.y, .width = width, .height = row.height }, fitted);
}

// Width of the slot before the workspace name: the favicon square when one
// is resolved, else one monospace cell for the generic glyph.
fn projectSlot(card: AgentCard, canvas: *const Canvas) f32 {
    if (card.project_icon != null) {
        return @max(card.geometry.glyph_width, card.markSide(canvas));
    }

    return card.geometry.glyph_width;
}

// The mark and the favicon are `CardGeometry.mark_size` logical pixels, the
// size the sprite page's cell is built for at this display scale.
fn markSide(_: AgentCard, canvas: *const Canvas) f32 {
    return @round(canvas.chrome.px(CardGeometry.mark_size));
}

// OpenAI follows the theme; the other providers retain their source colors.
// Custom providers keep their configured glyph without a background.
fn drawMark(card: AgentCard, canvas: *Canvas, chip: Rect) !void {
    const palette = canvas.theme.palette;
    if (canvas.providerMark(card.agent.provider)) |mark| {
        const tint: core.Color = if (card.agent.provider == .codex)
            (if (palette.text == .default) .{ .rgb = canvas.theme.terminal.foreground } else palette.text)
        else
            .default;
        try canvas.spriteTintedAt(chip, .{ .sprite = mark, .color = tint, .alpha = provider_alpha });
        return;
    }

    const glyph = card.providerGlyph();
    const label: Label = .{ .text = glyph, .color = palette.subtext0, .alpha = provider_alpha, .face = .sans, .size = .small };
    const width = try canvas.measure(label);
    const inset = @max(0, (chip.width - width) / 2);
    _ = try canvas.textAt(.{ .x = chip.x + inset, .y = chip.y, .width = chip.width - inset, .height = chip.height }, label);
}

fn providerGlyph(card: AgentCard) []const u8 {
    if (card.agent.iconGlyph().len != 0) {
        return card.agent.iconGlyph();
    }

    const icon = client.Icon.forProvider(card.agent.provider) orelse .provider_unknown;
    return icon.unicodeGlyph();
}
