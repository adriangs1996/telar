const ApplyTabRemovalHandler = @This();
const client_model = @import("../../root.zig").model;
const RemovalDelivery = @import("RemovalDelivery.zig");
const ApplyTabRemoval = @import("ApplyTabRemoval.zig");
const source_namespace = @import("close_tab.zig");
model: *client_model.Model,
delivery: RemovalDelivery,

/// Validates and commits one canonical tab-removal fact before delegating
/// its exact removed or stale result. Requested absence is rejected while
/// lifecycle absence remains an idempotent delivery.
///
/// ```zig
/// const directive = try handler.execute(command);
/// ```
pub fn execute(handler: *ApplyTabRemovalHandler, command: ApplyTabRemoval) !source_namespace.TabRemovalDirective {
    try source_namespace.validateWorkspaceTransition(command);

    const commit = try handler.model.removeTab(.{
        .location = command.location,
        .workspace_removed = command.workspace_removed,
    });

    if (commit == .stale and command.trigger == .requested) {
        return switch (commit.stale.absence) {
            .workspace => error.UnexpectedWorkspace,
            .tab => error.UnexpectedTab,
        };
    }

    return handler.delivery.deliver(
        handler.delivery.context,
        commit,
        command.previous_workspace,
    );
}
