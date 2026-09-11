const ApplyConfigHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("ConfigReloadEffects.zig");
const Command = @import("ConfigReloadCommand.zig");
const client_diagnostic = @import("client_diagnostic.zig");
model: *client_model.Model,
effects: Effects,

/// Commits semantic configuration, clears an obsolete diagnostic and
/// delivers concrete resources in deterministic application order.
///
/// ```zig
/// const commit = try handler.execute(command);
/// ```
pub fn execute(handler: *ApplyConfigHandler, command: Command) !client_model.ConfigurationCommit {
    const commit = try handler.model.applyConfiguration(command.configuration);
    var diagnostic_handler: client_diagnostic.ClientDiagnosticHandler = .{ .model = handler.model };
    _ = diagnostic_handler.clear();

    handler.effects.adopt_resources(handler.effects.context, commit);
    if (commit.bars_changed) {
        try handler.effects.synchronize_bars(handler.effects.context);
    }
    handler.effects.project_appearance(handler.effects.context, !command.theme_locked);
    try handler.effects.configure_sidebar(handler.effects.context);

    if (commit.sidebar) |sidebar| {
        try handler.effects.apply_sidebar(handler.effects.context, sidebar);
    } else if (commit.pane_gaps_changed) {
        handler.effects.invalidate_graphics_placements(handler.effects.context);
        try handler.effects.offer_active_pane_geometry(handler.effects.context);
    }

    return commit;
}
