//! Bounded configuration and presentation state for client-owned bars.

const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const GenericContent = @import("GenericContent.zig").Type;
const Node = @import("Node.zig");
const ContentLimits = @import("ContentLimits.zig");
const Dynamic = @import("Dynamic.zig");
const Command = @import("BarCommand.zig");
const std = @import("std");
const ui_icons = @import("../layout/icons.zig");
const Configuration = @import("BarConfiguration.zig");
const State = @import("State.zig");
const NodeKind = @import("NodeKind.zig").NodeKind;
const MetricName = @import("MetricName.zig").MetricName;

pub const max_segments = 16;
/// Legacy plain command output without a render callback stays one line of
/// at most this many bytes.
pub const max_text_bytes = 512;
pub const text_limit = core.Limit.declare("bars.max_text_bytes", "output bytes", max_text_bytes);
pub const max_panels = 16;
pub const panels_limit = core.Limit.declare("panels.max_panels", "panels", max_panels);
pub const max_picks = 16;
pub const picks_limit = core.Limit.declare("picks.max_picks", "picks", max_picks);
/// Enough click actions for one slot or panel to open every configured
/// panel and pick.
pub const max_content_actions = max_panels + max_picks;

pub const max_bar_nodes = 64;
pub const max_bar_text_bytes = 4096;
pub const max_bar_actions = max_content_actions;
/// Sparkline samples of one bar slot: two full sparklines and change.
pub const max_bar_samples = 256;
pub const max_panel_nodes = 128;
pub const max_panel_text_bytes = 16 * 1024;
pub const max_panel_actions = max_content_actions;
pub const max_panel_samples = 1024;

/// What a bar slot reports when a render returns more than it holds.
pub const bar_limits: ContentLimits = .{
    .nodes = core.Limit.declare("bars.max_bar_nodes", "components", max_bar_nodes),
    .text = core.Limit.declare("bars.max_bar_text_bytes", "text bytes", max_bar_text_bytes),
    .actions = core.Limit.declare("bars.max_bar_actions", "click actions", max_bar_actions),
    .samples = core.Limit.declare("bars.max_samples", "sparkline samples", max_bar_samples),
};
/// What a panel reports when a render returns more than it holds.
pub const panel_limits: ContentLimits = .{
    .nodes = core.Limit.declare("panels.max_panel_nodes", "components", max_panel_nodes),
    .text = core.Limit.declare("panels.max_panel_text_bytes", "text bytes", max_panel_text_bytes),
    .actions = core.Limit.declare("panels.max_panel_actions", "click actions", max_panel_actions),
    .samples = core.Limit.declare("panels.max_samples", "sparkline samples", max_panel_samples),
};
/// Values one `telar.ui.sparkline` keeps; the most recent ones stay.
pub const node_samples_limit = core.Limit.declare("bars.max_node_samples", "sparkline values", Node.max_samples);
/// Command output handed to a render callback, such as a JSON document.
pub const max_command_output_bytes = 64 * 1024;
pub const command_output_limit = core.Limit.declare("bars.max_command_output_bytes", "output bytes", max_command_output_bytes);
/// Output a pick's list command may print; `pi --list-models` prints
/// about 43 KiB.
pub const max_pick_output_bytes = 256 * 1024;
pub const pick_output_limit = core.Limit.declare("picks.max_pick_output_bytes", "output bytes", max_pick_output_bytes);

/// The components of one bar slot.
pub const Content = GenericContent(bar_limits.bounds());
/// The components of one open panel.
pub const PanelContent = GenericContent(panel_limits.bounds());
/// Everything one render returns before it is fitted into a slot or a
/// panel; the configuration generation keeps one on the heap.
pub const StagedContent = GenericContent(.{
    .nodes = Node.max_list_nodes,
    .text = 2 * max_panel_text_bytes,
    .actions = 2 * max_content_actions,
    .samples = 2 * max_panel_samples,
});

/// What `telar.bar.metrics()` shows: one group of CPU, memory and battery,
/// each formatted by the adapter from the runtime's latest sample.
pub const metrics_content: Content = metricsContent();

fn metricsContent() Content {
    @setEvalBranchQuota(100_000);
    var content: Content = .{};
    const group = content.append(.{
        .kind = .group,
        .priority = metric_priority,
    }) catch unreachable;
    for ([_]MetricName{ .cpu, .memory, .battery }) |name| {
        _ = content.append(.{
            .kind = .metric,
            .parent = group,
            .metric = name,
            .priority = metric_priority,
        }) catch unreachable;
    }

    return content;
}

/// What `telar.bar.machines()` shows: one component listing the window's
/// machines, filled by the adapter from its machines at draw time.
pub const machines_content: Content = machinesContent();

fn machinesContent() Content {
    var content: Content = .{};
    _ = content.append(.{
        .kind = .machines,
        .priority = metric_priority,
    }) catch unreachable;
    return content;
}

const metric_priority: u8 = 40;
pub const max_command_args = 32;
pub const max_command_bytes = 4096;
pub const min_interval_ms: u32 = 100;
pub const max_interval_ms: u32 = 60 * 60 * 1000;
pub const min_command_timeout_ms: u32 = 100;
/// Bar and panel commands share one worker, so a slow one delays every
/// other source; they stop within this.
pub const max_command_timeout_ms: u32 = 10_000;
/// A pick's list and `on_select` commands run in jobs of their own, when a
/// person opens or chooses, and may reach the network or install something.
pub const max_pick_timeout_ms: u32 = 60_000;

pub const Position = enum(u3) {
    bottom_left,
    bottom_center,
    bottom_right,
    top_right,
    sidebar_footer_left,
    sidebar_footer_center,
    sidebar_footer_right,

    pub fn bit(self: Position) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

pub const Alignment = enum {
    left,
    center,
    right,
};

pub const PaletteColor = enum {
    accent,
    panel_bg,
    surface0,
    surface1,
    surface_dim,
    overlay0,
    overlay1,
    text,
    subtext0,
    mauve,
    green,
    yellow,
    red,
    blue,
    teal,
    peach,
};

pub const Color = union(enum) {
    palette: PaletteColor,
    value: cellgrid.Color,
};

pub const Source = union(enum) {
    empty,
    tabs,
    metrics,
    machines,
    static: Content,
    dynamic: Dynamic,
    command: Command,

    pub fn interval(self: *const Source) ?u64 {
        return switch (self.*) {
            .dynamic => |value| value.interval_ns,
            .command => |value| value.interval_ns,
            else => null,
        };
    }
};

pub const Slot = union(enum) {
    empty,
    tabs,
    content: Content,
};

pub const Change = enum {
    unchanged,
    changed,
};

pub fn presentationSlot(source: *const Source) Slot {
    return switch (source.*) {
        .empty => .empty,
        .tabs => .tabs,
        .metrics => .{ .content = metrics_content },
        .machines => .{ .content = machines_content },
        .static => |content| .{ .content = content },
        .dynamic, .command => .{ .content = .{} },
    };
}

pub fn slotEql(left: *const Slot, right: *const Slot) bool {
    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) {
        return false;
    }

    return switch (left.*) {
        .content => |*content| content.eql(&right.content),
        else => true,
    };
}

test "legacy segments become labels that keep their exact style" {
    var content: Content = .{};
    try content.appendSegment(.{
        .text = " CPU 20%",
        .icon = .cpu,
        .style = .{ .foreground = .{ .palette = .teal }, .bold = true },
    });
    try content.appendSegment(.{ .text = "", .icon = .battery_full });

    try std.testing.expectEqual(@as(u8, 2), content.node_count);
    try std.testing.expectEqual(NodeKind.label, content.slice()[0].kind);
    try std.testing.expectEqualStrings(" CPU 20%", content.text(content.slice()[0].text));
    try std.testing.expect(content.slice()[0].style.bold);
    try std.testing.expectEqual(NodeKind.icon, content.slice()[1].kind);
    try std.testing.expectEqual(ui_icons.Icon.battery_full, content.slice()[1].icon.?);
}

test "bar state rejects stale dynamic updates and folds equal content" {
    const configuration: Configuration = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 7, .id = 1 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var state = State.init(configuration.presentation());
    var content: Content = .{};
    try content.appendSegment(.{ .text = "ready" });

    try std.testing.expectError(error.StaleBarUpdate, state.update(.{ .generation = 6, .position = .bottom_left, .content = content }));
    try std.testing.expectEqual(Change.changed, try state.update(.{ .generation = 7, .position = .bottom_left, .content = content }));
    try std.testing.expectEqual(Change.unchanged, try state.update(.{ .generation = 7, .position = .bottom_left, .content = content }));
}

test "bar text rejects terminal controls before it reaches the renderer" {
    var content: Content = .{};

    try std.testing.expectError(error.InvalidBarText, content.appendSegment(.{ .text = "line\n" }));
    try std.testing.expectError(error.InvalidBarText, content.appendSegment(.{ .text = "\x1b[31m" }));
}
