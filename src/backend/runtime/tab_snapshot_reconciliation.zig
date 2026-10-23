//! A client asks for one tab's snapshot to reconcile its replica.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const client_request = @import("client_request.zig");
const tab_hold = @import("tab_hold.zig");

/// Queues the tab snapshot, or `tab_not_found` for a tab without panes that
/// no client holds.
///
/// ```zig
/// try tab_snapshot_reconciliation.snapshot(model, session, request);
/// ```
pub fn snapshot(model: *RuntimeModel, session: *Session, request: core.RequestTabSnapshot) !void {
    // A tab without panes exists for clients only while one holds it (`tab_hold`).
    const empty = model.panes.countAt(request.location) == 0 and !tab_hold.held(model, request.location);
    if (!model.workspaces.contains(request.location) or empty) {
        return client_request.fail(session, request.request_id, .tab_not_found, "tab not found");
    }

    try session.delivery.responses.push(.{ .tab_snapshot = .{
        .request_id = request.request_id,
        .location = request.location,
    } });
}
