const RecoveryCapture = @This();
const source_namespace = @import("attach_pane.zig");
const tab_snapshot_recovery = @import("../tabs/root.zig").tab_snapshot_recovery;
calls: usize = 0,
location: ?source_namespace.schema.TabLocation = null,
fail: bool = false,

pub fn handler(capture: *RecoveryCapture) tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler {
    return .{ .effects = .{
        .context = capture,
        .pending = pending,
        .request = refresh,
    } };
}

fn pending(_: *anyopaque) bool {
    return false;
}

fn refresh(context: *anyopaque, location: source_namespace.schema.TabLocation) !void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.location = location;

    if (capture.fail) {
        return error.RefreshFailed;
    }
}
