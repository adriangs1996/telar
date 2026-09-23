//! A client acknowledges a delivered cell frame or asks for a full cell
//! snapshot of an attached pane.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");

/// Retires the outstanding frame the client applied.
///
/// ```zig
/// pane_frame.acknowledge(model, session, ack);
/// ```
pub fn acknowledge(model: *RuntimeModel, session: *Session, ack: core.FrameAck) void {
    const elapsed = session.attachments.acknowledgeFrame(ack, core.now(model.io)) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    if (comptime core.enabled) {
        model.metrics.ack.observe(elapsed);
    }
}

/// Schedules a full cell snapshot for an attached pane.
///
/// ```zig
/// pane_frame.snapshot(model, session, request);
/// ```
pub fn snapshot(model: *RuntimeModel, session: *Session, request: core.RequestSnapshot) void {
    if (!session.attachments.requestCellSnapshot(request.pane_id)) {
        model.metrics.stale_client_messages += 1;
    }
}
