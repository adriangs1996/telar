const TabLocationType = @import("telar-core").TabLocation;
const RequestTabSnapshotRecoveryHandlerType = @import("../tabs/RequestTabSnapshotRecoveryHandler.zig");
const RecoveryCapture = @This();

calls: usize = 0,
location: ?TabLocationType = null,
fail: bool = false,

pub fn handler(capture: *RecoveryCapture) RequestTabSnapshotRecoveryHandlerType {
    return .{ .effects = .{
        .context = capture,
        .pending = pending,
        .request = refresh,
    } };
}

fn pending(_: *anyopaque) bool {
    return false;
}

fn refresh(context: *anyopaque, location: TabLocationType) !void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.location = location;

    if (capture.fail) {
        return error.RefreshFailed;
    }
}
