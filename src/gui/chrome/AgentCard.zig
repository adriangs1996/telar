const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const AgentCard = @This();

context: *Context,
agent: *const client.Agent,

/// Registers every visible card line against its stable pane generation.
/// Example: `try card.paint(row, 0);`
pub fn paint(card: AgentCard, area: core.Rect, line: u2) !void {
    const palette = card.context.canvas.theme.palette;
    const action = @import("action.zig").Action{ .intent = .{ .focus_agent = card.agent.key } };
    const is_focused = card.focused();
    const hovered = if (card.context.hovered) |value| std.meta.eql(value, action) else false;
    try card.context.canvas.fill(area, if (is_focused) palette.surface0 else if (hovered) palette.surface1 else palette.panel_bg);
    try card.context.hits.add(.{ .area = area, .action = action });
    var buffer: [768]u8 = undefined;
    if (line == 0) {
        const status_text = card.status();
        const status_width = @min(core.measure(status_text) + 1, area.w);
        const title_area, const status_area = area.splitLeft(area.w - status_width);
        const title = if (card.agent.sessionTitle().len != 0) card.agent.sessionTitle() else card.agent.displayName();
        try card.context.canvas.text(title_area, .{ .text = title, .color = palette.text, .bold = true });
        try card.context.canvas.text(status_area, .{ .text = status_text, .color = card.statusColor() });
        return;
    }

    const label = if (line == 1)
        std.fmt.bufPrint(&buffer, "{s} / {s} / {d}", .{ card.agent.workspaceLabel(), card.agent.tabLabel(), card.paneIndex() }) catch unreachable
    else
        std.fmt.bufPrint(&buffer, "{s}  {s}", .{ card.agent.displayName(), card.agent.cwdLabel() }) catch unreachable;
    try card.context.label(area, label);
}

fn focused(card: AgentCard) bool {
    const model = card.context.projection.model orelse return false;
    if (model.layout.focused() != card.agent.key.pane_id) {
        return false;
    }

    const location = model.location orelse return false;
    return std.meta.eql(location, card.agent.location);
}

fn paneIndex(card: AgentCard) u16 {
    if (card.context.projection.model) |model| {
        if (model.location) |location| {
            if (std.meta.eql(location, card.agent.location)) {
                return model.layout.displayIndex(card.agent.key.pane_id) orelse card.agent.pane_index;
            }
        }
    }

    return card.agent.pane_index;
}

fn status(card: AgentCard) []const u8 {
    return switch (card.agent.status) {
        .working => if (card.context.projection.sidebar_animation_frame % 2 == 0) "● working" else "◌ working",
        .ready => "✓ ready",
        .done => "✓ done",
        .blocked => "! blocked",
        .failed => "× failed",
        .unknown => "? unknown",
    };
}

fn statusColor(card: AgentCard) core.Color {
    const palette = card.context.canvas.theme.palette;
    return switch (card.agent.status) {
        .working => palette.teal,
        .ready, .done => palette.green,
        .blocked => palette.yellow,
        .failed => palette.red,
        .unknown => palette.overlay1,
    };
}
