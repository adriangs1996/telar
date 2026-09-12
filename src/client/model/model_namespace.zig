//! Passive state owned by one disposable client.

const PaneType = @import("../panes/Pane.zig");
const model_types = @import("types.zig");
const std = @import("std");
const Model = @import("Model.zig");
const PaneViewportChange = @import("PaneViewportChange.zig");
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const WorkspaceDeparture = @import("WorkspaceDeparture.zig");
const LaunchSource = @import("LaunchSource.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const TabsModel = @import("../workspace/TabsModel.zig");
const TabLocationType = @import("telar-core").TabLocation;
const TabType = @import("../workspace/Tab.zig");
const PaneIdType = @import("telar-core").PaneId;

test {
    _ = @import("tests/configuration_and_host.zig");
    _ = @import("tests/input_and_frames.zig");
    _ = @import("tests/observations.zig");
    _ = @import("tests/panes.zig");
    _ = @import("tests/tabs.zig");
    _ = @import("tests/workspaces.zig");
}

pub fn paneViewportOffset(pane: *const PaneType, target: model_types.PaneViewportTarget) u32 {
    const maximum = pane.scroll.maxOffset(pane.buffer.h);

    return switch (target) {
        .absolute => |offset| @min(offset, maximum),
        .relative => |delta| @intCast(std.math.clamp(
            @as(i64, pane.scroll.offset) + @as(i64, delta),
            0,
            @as(i64, maximum),
        )),
        .bottom => maximum,
    };
}

pub fn commitPaneViewport(model: *Model, pane: *PaneType, offset: u32) ?PaneViewportChange {
    if (pane.scroll.offset == offset) {
        return null;
    }

    pane.scroll.offset = offset;
    model.viewport_revision +%= 1;

    return .{
        .pane_id = pane.id,
        .offset = offset,
        .at_bottom = pane.scroll.atBottom(pane.buffer.h),
        .viewport_revision = model.viewport_revision,
    };
}

pub fn copyModeViewport(pane: *const PaneType, wanted: u32) ?SetPaneViewportType {
    const offset = paneViewportOffset(pane, .{ .absolute = wanted });
    if (pane.scroll.offset == offset) {
        return null;
    }

    return .{ .pane_id = pane.id, .offset = offset };
}

pub fn releaseInvalidCopyMode(model: *Model) void {
    const state = model.copy_state orelse return;
    const active = model.workspace.activeConst() orelse {
        _ = model.releaseCopyMode(state.pane_id);
        return;
    };
    if (active.model.findConst(state.pane_id) != null) {
        return;
    }

    _ = model.releaseCopyMode(state.pane_id);
}

pub fn captureWorkspace(model: *Model) WorkspaceDeparture {
    const source = model.workspace.workspace orelse return .{};
    var departure: WorkspaceDeparture = .{ .source = source };
    if (model.workspace.activeConst()) |tab| {
        if (tab.model.focusedPaneConst()) |pane| {
            departure.bookmark = .{
                .location = tab.location,
                .pane_id = pane.id,
                .tab_layout = tab.model.layout,
            };
        }
    }

    var tabs = model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            departure.panes.append(pane.id);
        }
    }

    return departure;
}

pub fn focusedLaunchSource(model: *const Model) ?LaunchSource {
    const active = model.workspace.activeConst() orelse return null;
    const pane = active.model.focusedPaneConst() orelse return null;
    if (!pane.attached or !std.meta.eql(pane.location, active.location)) {
        return null;
    }

    return .{ .location = active.location, .pane_id = pane.id };
}

pub fn inheritCellSize(size: *TerminalSizeType, source: TerminalSizeType) void {
    size.cell_width_px = source.cell_width_px;
    size.cell_height_px = source.cell_height_px;
}

pub fn detachPane(pane: *PaneType) void {
    pane.attached = false;
    pane.pending_frame_id = 0;
}

pub fn findTab(workspace: *TabsModel, location: TabLocationType) ?*TabType {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}

pub fn findTabConst(workspace: *const TabsModel, location: TabLocationType) ?*const TabType {
    const index = workspace.indexOf(location.tab_id) orelse return null;
    const tab = &workspace.items[index].?;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}

test "resizing a mouse-selected pane cancels coordinates but retains gesture ownership" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    try std.testing.expect(model.beginPointerSelection(.{ .pane_id = pane_id, .position = .{ .x = 15, .y = 0 }, .now_ns = 0 }));
    const version = model.version();
    const pane = model.workspace.findPane(pane_id).?;
    try pane.buffer.resize(10, 5);

    try std.testing.expect(model.reconcileCopyModeFrame(.{ .pane_id = pane_id, .previous_offset = 0, .scroll = pane.scroll }));
    try std.testing.expect(model.copyModeProjection() == null);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
    try std.testing.expectEqual(pane_id, model.pointerSelection().?.pane_id);
    try std.testing.expect(model.pointerSelection().?.dragging);
    model.finishPointerGesture();
    try std.testing.expect(model.pointerSelection() == null);
}

test "copy mode frame reconciliation and pane release are exact" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 15, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 2, .y = 4 };
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    try std.testing.expect(!model.reconcileCopyModeFrame(.{
        .pane_id = @enumFromInt(2),
        .previous_offset = 10,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));
    try std.testing.expect(model.reconcileCopyModeFrame(.{
        .pane_id = pane_id,
        .previous_offset = 10,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));

    try std.testing.expectEqual(version.copy + 1, model.version().copy);
    try std.testing.expectEqual(@as(u32, 9), model.copyModeProjection().?.view.cursor.y);
    try std.testing.expect(!model.reconcileCopyModeFrame(.{
        .pane_id = pane_id,
        .previous_offset = 5,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));
    try std.testing.expect(!model.releaseCopyMode(@enumFromInt(2)));
    try std.testing.expect(model.releaseCopyMode(pane_id));
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expectEqual(version.copy + 2, model.version().copy);
}
