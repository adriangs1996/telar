//! A terminal client's layout is retained as one bounded replica per client
//! identity, checked against runtime state, and restored on reconnect.

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const ClientLayouts = @import("ClientLayouts.zig");
const limit_reached = @import("limit_reached.zig");

/// Retains the client's current layout for its identity.
///
/// ```zig
/// try client_layout_persistence.retain(model, session, update);
/// ```
pub fn retain(model: *RuntimeModel, session: *Session, update: core.ClientLayoutUpdateView) !void {
    const identity = session.delivery.client_identity;
    if (identity == .invalid) {
        return error.ClientLayoutNotSubscribed;
    }

    const evictions = model.client_layouts.evictions;
    try model.client_layouts.replace(identity, update, &model.panes, &model.workspaces);
    if (model.client_layouts.evictions != evictions) {
        limit_reached.report(model, .{
            .limit = ClientLayouts.identities_limit,
            .requested = core.max_client_layout_clients + 1,
        });
    }

    session_checkpoint.noteChange(model);
}
