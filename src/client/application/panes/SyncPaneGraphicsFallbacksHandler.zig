const ModelType = @import("../../model/Model.zig");
const FallbackEffects = @import("FallbackEffects.zig");
const std = @import("std");
const max_tabs_per_workspace_module = @import("telar-core").max_tabs_per_workspace;
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const SyncPaneGraphicsFallbacksHandler = @This();

model: *ModelType,
effects: FallbackEffects,

/// Reconciles every bounded pane fallback from committed host capability
/// state and the physical graphics owned by the client adapter.
///
/// ```zig
/// handler.execute();
/// ```
pub fn execute(handler: *SyncPaneGraphicsFallbacksHandler) void {
    const fallback_required = handler.model.hostCapabilities().images != .supported;
    var inspected: usize = 0;
    var tabs = handler.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            inspected += 1;
            const has_graphics = fallback_required and
                handler.effects.has_graphics(handler.effects.context, pane.id);
            _ = handler.model.setPaneGraphicsFallback(pane.id, has_graphics);
        }
    }

    std.debug.assert(inspected <= max_tabs_per_workspace_module * max_panes_per_tab_module);
}
