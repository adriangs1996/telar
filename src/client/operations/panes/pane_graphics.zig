//! Reconciles retained resources and semantic fallbacks using concrete dependencies.

const data = @import("model");
const Model = @import("../../model/Model.zig");
const GraphicsRetention = @import("../../graphics/GraphicsRetention.zig");

const std = @import("std");
const core = @import("telar-core");

/// Reconciles all fallbacks when host support changes. Example: `syncFallbacks(model, graphics);`
pub fn syncFallbacks(model: *Model, graphics: GraphicsRetention) void {
    const fallback_required = model.hostCapabilities().images != .supported;
    var inspected: usize = 0;
    var tabs = model.workspace.tabIterator();

    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();

        while (panes.next()) |pane| {
            inspected += 1;
            const has_graphics = fallback_required and
                graphics.hasPaneGraphics(pane.id);
            _ = model.setPaneGraphicsFallback(pane.id, has_graphics);
        }
    }

    std.debug.assert(inspected <= core.max_tabs_per_workspace * core.max_panes_per_tab);
}

/// Classifies bounded ingress recovery without sending runtime messages.
/// Example: `const result = try applyResources(graphics, command);`
pub fn applyResources(graphics: GraphicsRetention, command: data.PaneGraphicsCommand) !data.PaneGraphicsResourceResult {
    const before = graphics.ingressVersion();
    graphics.apply(command) catch |err| switch (err) {
        error.GraphicsResyncRequired => return .{ .resync_required = command.paneId() },
        error.GraphicsSharedMappingFailed => return .{ .shared_mapping_failed = command.paneId() },
        else => return err,
    };

    if (graphics.ingressVersion() == before) {
        return .unchanged;
    }

    const pane_id = command.paneId();
    return .{ .changed = .{
        .pane_id = pane_id,
        .has_graphics = graphics.hasPaneGraphics(pane_id),
    } };
}
