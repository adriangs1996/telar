//! An agent's status as a chip in pane chrome: the blocked reason, the
//! working age or the terminal status, in white on the status colour. The
//! pane header and the fullscreen band share it, so both bands read alike.
const data = @import("model");
const std = @import("std");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const attention = @import("attention.zig");
const Canvas = @import("Canvas.zig");
const AgentAges = @import("AgentAges.zig");
const StatusChip = @This();

context: *const Context,
agent: ?*const data.Agent,
/// The row the chip sits on; the chip starts at its left edge.
area: Rect,

pub const max_bytes = 32;
const inset: f32 = 6;
const height: f32 = 16;
const radius: f32 = 4;

/// The pixel width the chip reserves, or zero for a shell or an unknown status.
/// Example: `const reserved = try chip.width(canvas);`
pub fn width(self: StatusChip, canvas: *Canvas) !f32 {
    var storage: [max_bytes]u8 = undefined;
    const label = self.text(&storage);
    if (label.len == 0) {
        return 0;
    }

    return @ceil(try canvas.measure(.{ .text = label, .face = .sans, .size = .body }) + 2 * canvas.chrome.px(inset));
}

/// Paints the chip at the left edge of `area`, centred on the row.
/// Example: `try chip.draw(canvas);`
pub fn draw(self: StatusChip, canvas: *Canvas) !void {
    var storage: [max_bytes]u8 = undefined;
    const label = self.text(&storage);
    const chip_width = @min(self.area.width, try self.width(canvas));
    if (label.len == 0 or chip_width <= 0 or self.area.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const chip_height = @min(self.area.height, chrome.px(height));
    const bounds: Rect = .{ .x = self.area.x, .y = self.area.y + @floor((self.area.height - chip_height) / 2), .width = chip_width, .height = chip_height };
    try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(radius), .color = attention.statusColor(palette, self.agent.?.status) });
    _ = try canvas.textAt(.{ .x = bounds.x + chrome.px(inset), .y = self.area.y, .width = @max(0, chip_width - 2 * chrome.px(inset)), .height = self.area.height }, .{ .text = label, .color = palette.surface_dim, .face = .sans, .size = .body });
}

/// The chip's words, or an empty slice when the pane shows no chip.
/// Example: `const label = chip.text(&storage);`
pub fn text(self: StatusChip, storage: []u8) []const u8 {
    const agent = self.agent orelse return "";
    return switch (agent.status) {
        .blocked => switch (agent.blockedReason()) {
            .permission => "permission",
            .question => "question",
            .plan => "plan",
            .none, .other => "blocked",
        },
        .working => workingLabel(storage, self.context.statusAge(agent)),
        .done => "done",
        .failed => "failed",
        .ready => "ready",
        .unknown => "",
    };
}

fn workingLabel(storage: []u8, seconds: u32) []const u8 {
    var age_storage: [16]u8 = undefined;
    const age = attention.ageLabel(&age_storage, seconds);
    return std.fmt.bufPrint(storage, "working {s}", .{age}) catch "working";
}

test "status chip duration advances with the card clock between runtime reports" {
    var agents: data.AgentSnapshot = .{};
    const input: data.AgentInput = .{
        .key = .{
            .pane_id = @enumFromInt(1),
            .pane_generation = 1,
        },
        .location = .{
            .workspace = .{
                .workspace = @enumFromInt(1),
            },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
        .status_age_s = 5,
    };
    _ = try agents.replace(.{ .revision = 1, .agents = &.{input} });
    var ages: AgentAges = .{};
    const context: Context = .{ .hits = undefined, .bands = undefined, .projection = undefined, .hovered = null, .ages = &ages };
    const chip: StatusChip = .{ .context = &context, .agent = &agents.slice()[0], .area = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    var storage: [max_bytes]u8 = undefined;
    ages.observe(&agents, 100 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("working 5s", chip.text(&storage));
    ages.observe(&agents, 101 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("working 6s", chip.text(&storage));

    _ = try agents.replace(.{ .revision = 2, .agents = &.{input} });
    ages.observe(&agents, 101 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("working 6s", chip.text(&storage));
}
