const send_coordinator = @import("send_coordinator.zig");
const SendCoordinatorFakeSession = @import("SendCoordinatorFakeSession.zig");
const FakeCompletion = @import("FakeCompletion.zig");
const std = @import("std");
const Capture = @This();

steps: [16]send_coordinator.Step = undefined,
len: usize = 0,
resolved_client: u8 = 7,
resolve_client: bool = true,
session: SendCoordinatorFakeSession = .{},
completion: FakeCompletion = .{},
runtime_stopping: bool = false,
pump_failure: bool = false,
shutdown_complete: bool = false,
completion_saw_failure: bool = false,
finalized_client: ?u8 = null,
dropped_client: ?u8 = null,
detached_pane: ?u8 = null,

fn record(capture: *Capture, step: send_coordinator.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn resolve(capture: *Capture, client: u8) ?*SendCoordinatorFakeSession {
    capture.record(.resolve);

    if (!capture.resolve_client or client != capture.resolved_client) {
        return null;
    }

    return &capture.session;
}

pub fn recordStale(capture: *Capture) void {
    capture.record(.record_stale);
}

pub fn releaseSend(capture: *Capture, session: *SendCoordinatorFakeSession) void {
    capture.record(.release_send);
    session.send_pending = false;
}

pub fn isClosing(capture: *Capture, session: *SendCoordinatorFakeSession) bool {
    capture.record(.is_closing);
    return session.closing;
}

pub fn finalize(capture: *Capture, client: u8) void {
    capture.record(.finalize);
    capture.finalized_client = client;
}

pub fn completeDelivery(capture: *Capture, _: *SendCoordinatorFakeSession, result: anyerror!void) FakeCompletion {
    capture.record(.complete_delivery);
    capture.completion_saw_failure = if (result) |_| false else |_| true;
    return capture.completion;
}

pub fn dropClient(capture: *Capture, client: u8) void {
    capture.record(.drop_client);
    capture.dropped_client = client;
}

pub fn detachAfterSend(capture: *Capture, _: *SendCoordinatorFakeSession, pane: u8) void {
    capture.record(.detach_after_send);
    capture.detached_pane = pane;
}

pub fn shouldCloseAfterReply(capture: *Capture, session: *SendCoordinatorFakeSession) bool {
    capture.record(.should_close_after_reply);
    return session.close_after_reply;
}

pub fn stopping(capture: *Capture) bool {
    capture.record(.stopping);
    return capture.runtime_stopping;
}

pub fn pumpClient(capture: *Capture, _: *SendCoordinatorFakeSession) !void {
    capture.record(.pump_client);

    if (capture.pump_failure) {
        return error.SendFailed;
    }
}

pub fn pumpAll(capture: *Capture) void {
    capture.record(.pump_all);
}

pub fn shutdownDelivered(capture: *Capture) bool {
    capture.record(.shutdown_delivered);
    return capture.shutdown_complete;
}
