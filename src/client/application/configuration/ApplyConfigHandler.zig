const ModelType = @import("../../model/Model.zig");
const ConfigReloadEffects = @import("ConfigReloadEffects.zig");
const ConfigReloadCommand = @import("ConfigReloadCommand.zig");
const ConfigurationCommitType = @import("../../model/ConfigurationCommit.zig");
const ClientDiagnosticHandlerType = @import("ClientDiagnosticHandler.zig");
const ApplyConfigHandler = @This();

model: *ModelType,
effects: ConfigReloadEffects,

/// Commits semantic configuration, clears an obsolete diagnostic and
/// delivers concrete resources in deterministic application order.
///
/// ```zig
/// const commit = try handler.execute(command);
/// ```
pub fn execute(handler: *ApplyConfigHandler, command: ConfigReloadCommand) !ConfigurationCommitType {
    const commit = try handler.model.applyConfiguration(command.configuration);
    var diagnostic_handler: ClientDiagnosticHandlerType = .{ .model = handler.model };
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
