const TabCloseIntent = @import("TabCloseIntent.zig");
const close_tab = @import("close_tab.zig");
const CloseTabOperationGate = @import("CloseTabOperationGate.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
const PrepareTabCloseHandlerType = @import("PrepareTabCloseHandler.zig");
const RequestTabSnapshotRecoveryHandlerType = @import("RequestTabSnapshotRecoveryHandler.zig");
const std = @import("std");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const RequestCapture = @This();

blocked: bool = false,
prepare_failure: ?anyerror = null,
detach_failure: ?anyerror = null,
send_failure: ?anyerror = null,
restore_failure: ?anyerror = null,
intent: ?TabCloseIntent = null,
steps: [4]close_tab.RequestStep = undefined,
step_count: u8 = 0,

pub fn gate(capture: *RequestCapture) CloseTabOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn requestEffects(capture: *RequestCapture) CloseRequestEffects {
    return .{
        .context = capture,
        .detach = detach,
        .send = send,
    };
}

pub fn preparation(capture: *RequestCapture) PrepareTabCloseHandlerType {
    return .{
        .requests = .{
            .context = capture,
            .ensure = prepare,
        },
        .deliveries = .{
            .context = capture,
            .available = availableCapacity,
        },
        .pending_attachments = .{
            .context = capture,
            .pending = attachmentPending,
        },
    };
}

pub fn snapshots(capture: *RequestCapture) RequestTabSnapshotRecoveryHandlerType {
    return .{ .effects = .{
        .context = capture,
        .pending = snapshotPending,
        .request = restore,
    } };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn prepare(context: *anyopaque, _: u64) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.prepare);
    if (capture.prepare_failure) |failure| {
        return failure;
    }
}

fn availableCapacity(_: *anyopaque) usize {
    return std.math.maxInt(usize);
}

fn attachmentPending(_: *anyopaque, _: PaneIdType) bool {
    return false;
}

fn snapshotPending(_: *anyopaque) bool {
    return false;
}

fn detach(context: *anyopaque, _: TabLocationType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.detach);
    if (capture.detach_failure) |failure| {
        return failure;
    }
}

fn send(context: *anyopaque, intent: TabCloseIntent) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.send);
    capture.intent = intent;
    if (capture.send_failure) |failure| {
        return failure;
    }
}

fn restore(context: *anyopaque, _: TabLocationType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.restore);
    if (capture.restore_failure) |failure| {
        return failure;
    }
}

fn record(capture: *RequestCapture, step: close_tab.RequestStep) void {
    capture.steps[capture.step_count] = step;
    capture.step_count += 1;
}

pub fn recorded(capture: *const RequestCapture) []const close_tab.RequestStep {
    return capture.steps[0..capture.step_count];
}
