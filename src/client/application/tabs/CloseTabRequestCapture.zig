const RequestCapture = @This();
const TabCloseIntent = @import("TabCloseIntent.zig");
const source_namespace = @import("close_tab.zig");
const TabOperationGate = @import("CloseTabTabOperationGate.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
const tab_close_preparation = @import("tab_close_preparation.zig");
const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");
const std = @import("std");
blocked: bool = false,
prepare_failure: ?anyerror = null,
detach_failure: ?anyerror = null,
send_failure: ?anyerror = null,
restore_failure: ?anyerror = null,
intent: ?TabCloseIntent = null,
steps: [4]source_namespace.RequestStep = undefined,
step_count: u8 = 0,

pub fn gate(capture: *RequestCapture) TabOperationGate {
    return .{ .context = capture, .pending = pending };
}

pub fn requestEffects(capture: *RequestCapture) CloseRequestEffects {
    return .{
        .context = capture,
        .detach = detach,
        .send = send,
    };
}

pub fn preparation(capture: *RequestCapture) tab_close_preparation.PrepareTabCloseHandler {
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

pub fn snapshots(capture: *RequestCapture) tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler {
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

fn attachmentPending(_: *anyopaque, _: source_namespace.schema.PaneId) bool {
    return false;
}

fn snapshotPending(_: *anyopaque) bool {
    return false;
}

fn detach(context: *anyopaque, _: source_namespace.schema.TabLocation) !void {
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

fn restore(context: *anyopaque, _: source_namespace.schema.TabLocation) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.restore);
    if (capture.restore_failure) |failure| {
        return failure;
    }
}

fn record(capture: *RequestCapture, step: source_namespace.RequestStep) void {
    capture.steps[capture.step_count] = step;
    capture.step_count += 1;
}

pub fn recorded(capture: *const RequestCapture) []const source_namespace.RequestStep {
    return capture.steps[0..capture.step_count];
}
