//! Opens, closes and fills the panel shown above the bottom bar. A panel's
//! source runs only while it is open; every opening gets its own number so a
//! render started for an earlier opening never fills a later one.
const PanelReceipt = @import("PanelReceipt.zig").PanelReceipt;
const PanelUpdate = @import("PanelUpdate.zig");
const PanelOpening = @import("PanelOpening.zig");
const BarLayout = @import("BarLayout.zig");
const ClientModel = @import("../state/ClientModel.zig");
const LocalTime = @import("../state/LocalTime.zig");
const BarComponent = @import("BarComponent.zig");
const PanelRun = @import("../operations/configuration/PanelRun.zig");
const PanelTarget = @import("PanelTarget.zig").PanelTarget;
const bar_values = @import("model.zig");
const std = @import("std");

const anchored_positions = [_]bar_values.Position{ .bottom_left, .bottom_center, .bottom_right, .top_right };

/// Opens a panel, or closes it when that panel is already open, the way a
/// second click on the same component dismisses it.
///
/// ```zig
/// bar_panels.toggle(model, .{ .target = .{ .configured = 0 }, .anchor = anchor, .source = source, .now_ns = now });
/// ```
pub fn toggle(model: *ClientModel, opening: PanelOpening) void {
    const panel = &model.bars.panel;
    if (std.meta.eql(panel.target, opening.target)) {
        close(model);
        return;
    }

    const number = panel.opening +% 1;
    panel.* = .{
        .target = opening.target,
        .anchor = opening.anchor,
        .status = if (opening.target == .overflow) .ready else .loading,
        .opening = number,
    };

    model.bar_updates.stopPanel();
    if (opening.source) |source| {
        const index = panel.configured().?;
        if (source.interval() != null) {
            model.bar_updates.startPanel(.{
                .index = index,
                .opening = number,
            }, opening.now_ns);
        }
    }

    model.bars_revision +%= 1;
}

/// Example: `bar_panels.close(model);`
pub fn close(model: *ClientModel) void {
    const panel = &model.bars.panel;
    if (!panel.isOpen()) {
        return;
    }

    panel.* = .{ .opening = panel.opening +% 1 };
    model.bar_updates.stopPanel();
    model.bars_revision +%= 1;
}

/// Runs the open panel's source at the next tick.
/// Example: `bar_panels.refresh(model, now_ns);`
pub fn refresh(model: *ClientModel, now_ns: u64) void {
    if (model.bar_updates.panel_run == null) {
        return;
    }

    model.bar_updates.panel_deadline = now_ns;
}

/// Fills the open panel with a finished render of its own opening.
/// Example: `_ = bar_panels.receive(model, .{ .generation = 3, .run = run, .content = content, .time = now });`
pub fn receive(model: *ClientModel, update: PanelUpdate) PanelReceipt {
    if (!isCurrent(model, update.generation, update.run)) {
        return .stale;
    }

    const panel = &model.bars.panel;
    panel.content = update.content;
    panel.status = .ready;
    panel.updated = update.time;
    model.bars_revision +%= 1;
    return .updated;
}

/// Marks the open panel failed, keeping the last content it showed.
/// Example: `_ = bar_panels.fail(model, generation, run);`
pub fn fail(model: *ClientModel, generation: u64, run: PanelRun) PanelReceipt {
    if (!isCurrent(model, generation, run)) {
        return .stale;
    }

    model.bars.panel.status = .failed;
    model.bars_revision +%= 1;
    return .updated;
}

/// The first bar component that opens a panel, so a panel opened by a key
/// binding still appears above the component that represents it.
/// Example: `const anchor = bar_panels.anchorFor(&model.bars.layout, index);`
pub fn anchorFor(layout: *const BarLayout, index: u8) ?BarComponent {
    for (anchored_positions) |position| {
        const content = layout.content(position) orelse continue;
        for (content.slice(), 0..) |node, node_index| {
            const action = content.action(node) orelse continue;
            if (action == .open_panel and action.open_panel == index) {
                return .{
                    .position = position,
                    .node = @intCast(node_index),
                };
            }
        }
    }

    return null;
}

fn isCurrent(model: *const ClientModel, generation: u64, run: PanelRun) bool {
    const panel = &model.bars.panel;
    if (generation != model.configuration_generation) {
        return false;
    }

    return panel.opening == run.opening and panel.configured() == run.index;
}

test "a panel opens, ignores renders for an earlier opening and closes on a second toggle" {
    var model: ClientModel = undefined;
    model.bars = .{};
    model.bar_updates = .{};
    model.bars_revision = 0;
    model.configuration_generation = 2;
    const source: bar_values.Source = .{ .dynamic = .{ .callback = .{ .generation = 2, .id = 0 }, .interval_ns = 0 } };

    toggle(&model, .{
        .target = .{ .configured = 0 },
        .source = &source,
        .now_ns = 10,
    });
    const first = model.bar_updates.panel_run.?;
    toggle(&model, .{
        .target = .{ .configured = 1 },
        .source = &source,
        .now_ns = 20,
    });

    var content: bar_values.PanelContent = .{};
    _ = try content.append(.{
        .kind = .heading,
        .text = "On track",
    });
    try std.testing.expectEqual(PanelReceipt.stale, receive(&model, .{
        .generation = 2,
        .run = first,
        .content = content,
        .time = .epoch,
    }));

    const second = model.bar_updates.panel_run.?;
    try std.testing.expectEqual(PanelReceipt.updated, receive(&model, .{
        .generation = 2,
        .run = second,
        .content = content,
        .time = .epoch,
    }));
    try std.testing.expectEqual(@as(u8, 1), model.bars.panel.content.node_count);

    toggle(&model, .{
        .target = .{ .configured = 1 },
        .source = &source,
        .now_ns = 30,
    });
    try std.testing.expect(!model.bars.panel.isOpen());
    try std.testing.expect(model.bar_updates.panel_run == null);
}
