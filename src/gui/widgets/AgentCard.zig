//! One three-row agent card: project and status, a regular-weight title,
//! then the live event while working or the workspace branch at rest. The card paints only;
//! the sidebar owns its position, its hit target and its clipping.
const cellgrid = @import("cellgrid");
const data = @import("model");
const action_module = @import("action.zig");
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
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
agent: *const data.Agent,
geometry: CardGeometry,
/// Seconds the status has held, including the time since the snapshot arrived.
age_s: u32,
/// The workspace favicon in the sprite page once the favicon worker has
/// resolved it; `null` draws `project_glyph`.
project_icon: ?Sprite = null,

/// Draws the card at its composed bounds. Selection follows the focused pane;
/// hover comes from the context. Example: `try card.draw(canvas);`
pub fn draw(self: AgentCard, canvas: *Canvas) !void {
    const bounds = self.bounds;
    const palette = canvas.theme.palette;
    const hovered = if (self.context.hovered) |value| std.meta.eql(value, self.action()) else false;
    if (self.selected()) {
        try canvas.fillRoundedAt(bounds, .{ .radius = self.geometry.px(CardGeometry.radius), .color = palette.surface0 });
        try canvas.ringAt(bounds, .{ .width = 1, .radius = self.geometry.px(CardGeometry.radius), .color = palette.surface1 });
    } else if (hovered) {
        try canvas.fillRoundedAt(bounds, .{ .radius = self.geometry.px(CardGeometry.radius), .color = palette.surface1 });
    }

    const first_row = self.geometry.row(bounds, 0);
    try self.drawProject(canvas, first_row);
    try self.drawTitle(canvas, self.geometry.row(bounds, 1));
    try self.drawDetail(canvas, self.geometry.row(bounds, 2));
}

/// The action a click on the card performs.
/// Example: `try hits.add(.{ .area = cells, .action = card.action() });`
pub fn action(self: AgentCard) action_module.Action {
    return .{ .intent = .{ .focus_agent = self.agent.key } };
}

/// Borrows the live event or the branch of this agent's own workspace.
/// Missing Git observations and worktree-only locations have no branch fallback.
/// Example: `const detail = card.detailText();`
pub fn detailText(self: AgentCard) []const u8 {
    if (self.agent.status == .working) {
        return self.agent.lastEvent();
    }

    const workspace = switch (self.agent.location.workspace) {
        .workspace => |id| id,
        .worktree => return "",
    };
    const workspaces = self.context.projection.workspaces;
    const index = workspaces.indexOf(workspace) orelse return "";
    return workspaces.branchAt(index);
}

/// Whether the focused pane of the active tab is this agent's pane.
/// Example: `if (card.selected()) drawRing();`
pub fn selected(self: AgentCard) bool {
    const projection = self.context.projection;
    const tab = projection.tab orelse return false;
    if (projection.model.tabs.layout[tab].focused() != self.agent.key.pane_id) {
        return false;
    }

    return std.meta.eql(projection.model.tabs.location[tab], self.agent.location);
}

fn drawProject(self: AgentCard, canvas: *Canvas, row: Rect) !void {
    const palette = canvas.theme.palette;
    const gap = self.geometry.px(4);
    const slot = self.projectSlot(canvas);
    const reserved = @min(row.width / 2, slot + gap + self.geometry.px(24));
    const status_width = try self.drawStatus(canvas, .{ .x = row.x + reserved, .y = row.y, .width = row.width - reserved, .height = row.height });
    const project_width = @max(0, row.width - status_width - self.geometry.px(CardGeometry.gap));
    if (project_width < slot) {
        return;
    }

    if (self.project_icon) |icon| {
        const side = @min(self.markSide(canvas), row.height);
        try canvas.spriteAt(.{ .x = row.x + (slot - side) / 2, .y = row.y + (row.height - side) / 2, .width = side, .height = side }, icon);
    } else {
        try canvas.iconAt(.{ .x = row.x, .y = row.y, .width = slot, .height = row.height }, .{ .text = project_glyph, .color = palette.subtext0, .face = .sans, .size = .small });
    }

    const label_x = row.x + slot + gap;
    const label_width = @max(0, project_width - slot - gap);
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = label_width };
    var label_buffer: [core.max_agent_workspace_label_bytes + 16]u8 = undefined;
    const label_text = if (self.context.projection.workspaces.delegates(self.agent.key.pane_id))
        std.fmt.bufPrint(&label_buffer, "{s} \u{00b7} coordinator", .{self.agent.workspaceLabel()}) catch self.agent.workspaceLabel()
    else
        self.agent.workspaceLabel();
    const label: Label = .{ .text = label_text, .color = palette.subtext0, .face = .sans, .size = .small };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(.{ .x = label_x, .y = row.y, .width = label_width, .height = row.height }, fitted);
}

// The top-right slot drops duration, then the word, before clipping its
// glyph. Only the glyph pulses; the state and the clock remain readable.
/// Draws the status glyph, word and age at the right of `row`; returns the width used.
/// Example: `const used = try card.drawStatus(canvas, row);`
pub fn drawStatus(self: AgentCard, canvas: *Canvas, row: Rect) !f32 {
    const state = self.agent.status;
    const ink = status_glyph.color(canvas.theme.palette, state);
    const gap = self.geometry.px(6);
    const word = status_glyph.label(state, self.agent.blockedReason());
    var age_buffer: [age_label.max_bytes]u8 = undefined;
    var text_buffer: [32]u8 = undefined;
    const text = switch (state) {
        .working => std.fmt.bufPrint(&text_buffer, "{s} {s}", .{ word, age_label.duration(self.age_s, &age_buffer) }) catch unreachable,
        .ready => age_label.format(self.age_s, &age_buffer),
        else => word,
    };
    var glyph: Label = .{ .text = if (state == .ready) "" else status_glyph.glyph(state, self.agent.blockedReason()), .color = ink, .face = .sans, .size = .title };
    const glyph_width = if (glyph.text.len == 0) 0 else canvas.iconSize(glyph);
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
        const frame: u8 = if (canvas.animation) |clock| @truncate(clock.step(120 * std.time.ns_per_ms)) else self.context.projection.sidebar_animation_frame;
        glyph.alpha = status_glyph.pulse(frame);
    }

    if (glyph_width > 0) {
        try canvas.iconAt(.{ .x = left, .y = row.y, .width = @min(used, glyph_width), .height = row.height }, glyph);
    }

    if (label_width > 0) {
        _ = try canvas.textAt(.{ .x = row.x + row.width - label_width, .y = row.y, .width = label_width, .height = row.height }, label);
    }

    return used;
}

fn drawTitle(self: AgentCard, canvas: *Canvas, row: Rect) !void {
    const text = if (self.agent.sessionTitle().len != 0) self.agent.sessionTitle() else self.agent.displayName();
    const label: Label = .{ .text = text, .color = canvas.theme.palette.text, .face = .sans, .size = .title };
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = row.width };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(row, fitted);
}

fn drawDetail(self: AgentCard, canvas: *Canvas, row: Rect) !void {
    const side = self.markSide(canvas);
    var width = row.width;
    if (side <= row.width) {
        try self.drawMark(canvas, .{ .x = row.x + row.width - side, .y = row.y + (row.height - side) / 2, .width = side, .height = side });
        width = @max(0, width - side - self.geometry.px(CardGeometry.gap));
    }

    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = width };
    const label: Label = .{ .text = self.detailText(), .color = canvas.theme.palette.overlay1, .face = .sans, .size = .small };
    var fitted = label;
    fitted.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(.{ .x = row.x, .y = row.y, .width = width, .height = row.height }, fitted);
}

// Width of the slot before the workspace name: the favicon square when one
// is resolved, else the generic icon's text-relative square.
fn projectSlot(self: AgentCard, canvas: *const Canvas) f32 {
    if (self.project_icon != null) {
        return @max(self.geometry.glyph_width, self.markSide(canvas));
    }

    return canvas.iconSize(.{ .text = project_glyph, .size = .small });
}

// The mark and the favicon are `CardGeometry.mark_size` logical pixels, the
// size the sprite page's cell is built for at this display scale.
fn markSide(_: AgentCard, canvas: *const Canvas) f32 {
    return @round(canvas.chrome.px(CardGeometry.mark_size));
}

// OpenAI, Cursor and OpenCode follow the theme; the other providers retain
// their source colors.
// Custom providers keep their configured glyph without a background.
fn drawMark(self: AgentCard, canvas: *Canvas, chip: Rect) !void {
    const palette = canvas.theme.palette;
    if (canvas.providerMark(self.agent.provider)) |mark| {
        const tint: cellgrid.Color = if (data.icons.providerMarkFollowsTheme(self.agent.provider))
            (if (palette.text.kind == .default) .rgb(canvas.theme.terminal.foreground) else palette.text)
        else
            .default;
        try canvas.spriteTintedAt(chip, .{ .sprite = mark, .color = tint, .alpha = provider_alpha });
        return;
    }

    const glyph = self.providerGlyph();
    const label: Label = .{ .text = glyph, .color = palette.subtext0, .alpha = provider_alpha, .face = .sans, .size = .small };
    const width = try canvas.measure(label);
    const inset = @max(0, (chip.width - width) / 2);
    _ = try canvas.textAt(.{ .x = chip.x + inset, .y = chip.y, .width = chip.width - inset, .height = chip.height }, label);
}

fn providerGlyph(self: AgentCard) []const u8 {
    if (self.agent.iconGlyph().len != 0) {
        return self.agent.iconGlyph();
    }

    const icon = data.icons.Icon.forProvider(self.agent.provider) orelse .provider_unknown;
    return icon.unicodeGlyph();
}
