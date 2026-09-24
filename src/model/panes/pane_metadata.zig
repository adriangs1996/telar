//! A pane's metadata and progress as the runtime reports them.

const multiplexer_module = @import("../workspace/multiplexer.zig");
const PaneMetadataCommit = @import("../state/PaneMetadataCommit.zig");
const std = @import("std");
const tab_label = @import("../workspace/tab_label.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Stores one runtime-owned pane metadata fact. Stale pane reports and
/// exact repeats are ignored. Cwd moves that retain the same bounded
/// display name commit storage without publishing a presentation change.
///
/// ```zig
/// const commit = try pane_metadata.update(model, command);
/// ```
pub fn update(model: *ClientModel, command: model_data.PaneMetadataCommand) !?PaneMetadataCommit {
    const pane_id = switch (command) {
        .cwd => |cwd| cwd.pane_id,
        .foreground => |foreground| foreground.pane_id,
        .title => |title| title.pane_id,
    };
    const kind = std.meta.activeTag(command);
    const change: multiplexer_module.MetadataChange = if (model.panes.find(pane_id)) |pane| switch (command) {
        .cwd => |cwd| if (std.mem.eql(u8, pane.cwdSlice(), cwd.path))
            .unchanged
        else if (try pane.setCwd(cwd.path))
            .display_changed
        else
            .stored,
        .foreground => |foreground| if (pane.setForegroundName(foreground.name)) .display_changed else .unchanged,
        .title => |title| if (try pane.setTitle(title.title)) .display_changed else .unchanged,
    } else switch (command) {
        .foreground => |foreground| detached: {
            const slot = std.mem.findScalar(core.PaneId, model.tabs.foreground_pane[0..model.tabs.count], pane_id) orelse return null;
            const report: core.PaneForeground = .{
                .pane_id = foreground.pane_id,
                .name = foreground.name,
            };
            break :detached if (tab_label.applyForegroundReport(model, slot, report)) .display_changed else .unchanged;
        },
        .cwd, .title => return null,
    };
    if (change == .unchanged) {
        return null;
    }

    const display_changed = change == .display_changed;
    if (display_changed) {
        model.pane_metadata_revision +%= 1;
    }
    if (kind == .foreground) {
        std.debug.assert(display_changed);
        model.pane_foreground_revision +%= 1;
    }

    return .{
        .pane_id = pane_id,
        .kind = kind,
        .display_changed = display_changed,
        .pane_metadata_revision = model.pane_metadata_revision,
        .pane_foreground_revision = model.pane_foreground_revision,
    };
}

/// Applies one runtime-owned progress fact to its pane replica.
///
/// ```zig
/// const commit = pane_metadata.updateProgress(model, progress) orelse return;
/// ```
pub fn updateProgress(model: *ClientModel, progress: core.PaneProgress) ?model_data.PaneProgressCommit {
    const pane = model.panes.find(progress.pane_id) orelse return null;
    if (!pane.setProgress(progress)) {
        return null;
    }

    model.pane_progress_revision +%= 1;
    return .{
        .pane_id = progress.pane_id,
        .active = progress.state != .remove,
        .pane_progress_revision = model.pane_progress_revision,
    };
}
