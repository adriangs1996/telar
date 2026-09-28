//! The sidebar card of an agent working in a worktree: what task it serves,
//! what it is doing and how much it changed, without its project, which the
//! group already names. In full it has three rows: the branch, diff and last
//! command beside the status; the task title; and what happens now (the plan
//! step, the question it asks, or its final answer). Compact, it is one line.
//! The card paints only; the sidebar owns its position, hit target and clip.
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const client = @import("telar-client");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const CardGeometry = @import("CardGeometry.zig");
const AgentCard = @import("AgentCard.zig");
const Label = @import("Label.zig");
const TextFit = @import("TextFit.zig");
const age_label = @import("age_label.zig");
const status_glyph = @import("status_glyph.zig");
const action_module = @import("action.zig");
const FleetCard = client.FleetCard;
const TaskCard = @This();

/// Cells of the plan bar, one per task up to this many.
const max_plan_cells = 8;

context: *const Context,
bounds: Rect,
agent: *const data.Agent,
task: *const data.WorktreeRow,
card: FleetCard,
/// Drawn under the agent that created the task, with a guide line.
nested: bool = false,
geometry: CardGeometry,
age_s: u32,

/// Draws the card at its composed bounds. Example: `try card.draw(canvas);`
pub fn draw(self: TaskCard, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    const radius = self.geometry.px(CardGeometry.radius);
    const hovered = if (self.context.hovered) |value| std.meta.eql(value, self.action()) else false;
    if (self.base().selected()) {
        try canvas.fillRoundedAt(self.bounds, .{ .radius = radius, .color = palette.surface0 });
        try canvas.ringAt(self.bounds, .{ .width = 1, .radius = radius, .color = palette.surface1 });
    } else if (hovered) {
        try canvas.fillRoundedAt(self.bounds, .{ .radius = radius, .color = palette.surface1 });
    }

    if (self.nested) {
        try canvas.fillAt(.{ .x = self.bounds.x - self.geometry.px(CardGeometry.task_indent) / 2, .y = self.bounds.y, .width = 1, .height = self.bounds.height }, palette.surface1);
    }

    switch (self.card) {
        .task_compact => try self.drawCompact(canvas),
        .agent, .task_full => try self.drawFull(canvas),
    }
}

/// A click focuses the agent's pane, which opens the worktree's tab.
/// Example: `try hits.add(.{ .area = cells, .action = card.action() });`
pub fn action(self: TaskCard) action_module.Action {
    return .{ .intent = .{ .focus_agent = self.agent.key } };
}

fn base(self: TaskCard) AgentCard {
    return .{
        .context = self.context,
        .bounds = self.bounds,
        .agent = self.agent,
        .geometry = self.geometry,
        .age_s = self.age_s,
    };
}

fn drawFull(self: TaskCard, canvas: *Canvas) !void {
    const first = self.geometry.row(self.bounds, 0);
    const status_width = try self.base().drawStatus(canvas, first);
    const facts_width = @max(0, first.width - status_width - self.geometry.px(CardGeometry.gap));
    try self.drawFacts(canvas, .{ .x = first.x, .y = first.y, .width = facts_width, .height = first.height });
    try fitted(canvas, self.geometry.row(self.bounds, 1), .{ .text = self.task.displayName(), .color = canvas.theme.palette.text, .bold = true, .face = .sans, .size = .title });
    try self.drawActivity(canvas, self.geometry.row(self.bounds, 2));
}

fn drawCompact(self: TaskCard, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    const inset = self.geometry.px(CardGeometry.padding_x);
    const row: Rect = .{
        .x = self.bounds.x + inset,
        .y = self.bounds.y + self.geometry.px(CardGeometry.compact_padding_y),
        .width = @max(0, self.bounds.width - 2 * inset),
        .height = self.geometry.title_row,
    };
    const status = self.agent.status;
    var glyph: Label = .{ .text = status_glyph.glyph(status, self.agent.blockedReason()), .color = status_glyph.color(palette, status), .face = .sans, .size = .small };
    if (status == .working) {
        const frame: u8 = if (canvas.animation) |clock| @truncate(clock.step(120 * std.time.ns_per_ms)) else self.context.projection.sidebar_animation_frame;
        glyph.alpha = status_glyph.pulse(frame);
    }

    const glyph_width = canvas.iconSize(glyph);
    try canvas.iconAt(.{ .x = row.x, .y = row.y, .width = glyph_width, .height = row.height }, glyph);

    var age_buffer: [age_label.max_bytes]u8 = undefined;
    var right_buffer: [core.max_git_branch_bytes + age_label.max_bytes + 8]u8 = undefined;
    const right_text = std.fmt.bufPrint(&right_buffer, "\u{2387} {s}  {s}", .{ self.task.handle(), age_label.format(self.age_s, &age_buffer) }) catch self.task.handle();
    const right: Label = .{ .text = right_text, .color = palette.overlay1, .face = .sans, .size = .small };
    const right_width = @min(row.width / 2, try canvas.measure(right));
    try fitted(canvas, .{ .x = row.x + row.width - right_width, .y = row.y, .width = right_width, .height = row.height }, right);

    const gap = self.geometry.px(CardGeometry.gap);
    const title_x = row.x + glyph_width + gap;
    const dim = status == .ready;
    try fitted(canvas, .{ .x = title_x, .y = row.y, .width = @max(0, row.x + row.width - right_width - gap - title_x), .height = row.height }, .{ .text = self.task.displayName(), .color = if (dim) palette.overlay1 else palette.text, .face = .sans, .size = .body });
}

/// `⎇ branch  +12 −3 · 2  ✓ test`: where the task lives, how much it
/// changed and how its last command ended.
fn drawFacts(self: TaskCard, canvas: *Canvas, row: Rect) !void {
    const palette = canvas.theme.palette;
    var buffer: [TextFit.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("\u{2387} {s}", .{self.task.handle()}) catch {};
    if (self.task.diff_files != 0) {
        writer.print("  +{d} \u{2212}{d} \u{00b7} {d}", .{ self.task.diff_added, self.task.diff_removed, self.task.diff_files }) catch {};
    }

    if (self.task.commits_ahead != 0) {
        writer.print("  \u{2191}{d}", .{self.task.commits_ahead}) catch {};
    }

    switch (self.task.command_state) {
        .none => {},
        .running => {},
        .exited => writer.print("  {s} {s}", .{ if (self.task.command_exit == 0) "\u{2713}" else "\u{2715}", self.task.commandLabel() }) catch {},
    }

    try fitted(canvas, row, .{ .text = writer.buffered(), .color = palette.subtext0, .face = .sans, .size = .small });
}

/// What the agent does now: the question or approval it waits for, its
/// plan step with a bar, its final answer, or its last tool call.
fn drawActivity(self: TaskCard, canvas: *Canvas, row: Rect) !void {
    const palette = canvas.theme.palette;
    const agent = self.agent;
    var left = row.x;
    const text: []const u8, const color = switch (agent.status) {
        .blocked => .{ agent.lastEvent(), palette.yellow },
        .done, .ready => .{ if (agent.finalLine().len != 0) agent.finalLine() else agent.lastEvent(), palette.subtext0 },
        .failed => .{ agent.lastEvent(), palette.red },
        .working, .unknown => activity: {
            if (agent.plan_total != 0) {
                left += try self.drawPlanBar(canvas, row);
                break :activity .{ agent.planStep(), palette.subtext0 };
            }

            break :activity .{ agent.lastEvent(), palette.overlay1 };
        },
    };

    try fitted(canvas, .{ .x = left, .y = row.y, .width = @max(0, row.x + row.width - left), .height = row.height }, .{ .text = text, .color = color, .face = .sans, .size = .small });
}

/// `▰▰▱▱ 2/4 `: one cell per task, filled for completed ones.
fn drawPlanBar(self: TaskCard, canvas: *Canvas, row: Rect) !f32 {
    const palette = canvas.theme.palette;
    const cells = @min(self.agent.plan_total, max_plan_cells);
    const cell_width = self.geometry.px(8);
    const cell_gap = self.geometry.px(2);
    const cell_height = self.geometry.px(4);
    const filled = if (self.agent.plan_total == 0) 0 else (@as(usize, self.agent.plan_done) * cells + self.agent.plan_total - 1) / self.agent.plan_total;
    var x = row.x;
    for (0..cells) |index| {
        const color = if (index < filled) palette.teal else palette.surface1;
        try canvas.fillRoundedAt(.{ .x = x, .y = row.y + (row.height - cell_height) / 2, .width = cell_width, .height = cell_height }, .{ .radius = cell_height / 2, .color = color });
        x += cell_width + cell_gap;
    }

    var buffer: [16]u8 = undefined;
    const count: Label = .{ .text = std.fmt.bufPrint(&buffer, "{d}/{d}", .{ self.agent.plan_done, self.agent.plan_total }) catch "", .color = palette.subtext0, .face = .sans, .size = .small };
    const count_width = try canvas.measure(count);
    _ = try canvas.textAt(.{ .x = x + cell_gap, .y = row.y, .width = count_width, .height = row.height }, count);
    return x - row.x + cell_gap + count_width + self.geometry.px(CardGeometry.gap);
}

fn fitted(canvas: *Canvas, area: Rect, label: Label) !void {
    if (area.width <= 0) {
        return;
    }

    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fit: TextFit = .{ .canvas = canvas, .width = area.width };
    var shown = label;
    shown.text = try fit.fit(label, &buffer);
    _ = try canvas.textAt(area, shown);
}
