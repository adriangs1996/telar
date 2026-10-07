//! Passive state owned by one disposable client.
const copy_mode = @import("../input/copy_mode.zig");
const core = @import("telar-core");
const model_data = @import("../model.zig");

const Pane = @import("../panes/Pane.zig");
const std = @import("std");
const ClientModel = @import("ClientModel.zig");
const LaunchSource = @import("LaunchSource.zig");
const tab_layout = @import("../workspace/tab_layout.zig");

pub fn paneViewportOffset(pane: *const Pane, target: model_data.PaneViewportTarget) u32 {
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

pub fn commitPaneViewport(model: *ClientModel, pane: *Pane, offset: u32) ?model_data.PaneViewportChange {
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

pub fn copyModeViewport(pane: *const Pane, wanted: u32) ?core.SetPaneViewport {
    const offset = paneViewportOffset(pane, .{ .absolute = wanted });
    if (pane.scroll.offset == offset) {
        return null;
    }

    return .{ .pane_id = pane.id, .offset = offset };
}

pub fn releaseInvalidCopyMode(model: *ClientModel) void {
    const state = model.copy_state orelse return;
    if (model.activePaneConst(state.pane_id) != null) {
        return;
    }

    _ = copy_mode.release(model, state.pane_id);
}

pub fn captureWorkspace(model: *ClientModel) model_data.WorkspaceDeparture {
    const source = model.workspace orelse return .{};
    var departure: model_data.WorkspaceDeparture = .{ .source = source };
    if (model.tabs.activeSlot()) |slot| {
        if (tab_layout.focusedPaneConst(model, slot)) |pane| {
            departure.bookmark = .{
                .location = model.tabs.location[slot],
                .pane_id = pane.id,
                .tab_layout = model.tabs.layout[slot],
            };
        }
    }

    var panes = model.panes.iterateConst(null);
    while (panes.next()) |pane| {
        departure.panes.append(pane.id);
    }

    return departure;
}

pub fn focusedLaunchSource(model: *const ClientModel) ?LaunchSource {
    const slot = model.tabs.activeSlot() orelse return null;
    const location = model.tabs.location[slot];
    const pane = tab_layout.focusedPaneConst(model, slot) orelse return null;
    if (!pane.attached or !std.meta.eql(pane.location, location)) {
        return null;
    }

    return .{ .location = location, .pane_id = pane.id };
}

pub fn inheritCellSize(size: *core.TerminalSize, source: core.TerminalSize) void {
    size.cell_width_px = source.cell_width_px;
    size.cell_height_px = source.cell_height_px;
}

pub fn detachPane(pane: *Pane) void {
    pane.attached = false;
    pane.pending_frame_id = 0;
}

/// The slot of the tab at exactly `location`, including its workspace.
pub fn findTab(model: *const ClientModel, location: core.TabLocation) ?usize {
    const slot = model.tabs.find(location.tab_id) orelse return null;
    if (!std.meta.eql(model.tabs.location[slot], location)) {
        return null;
    }

    return slot;
}
