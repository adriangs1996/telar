const IntegrationContext = @This();
const FakeSession = @import("FakeSession.zig");
const std = @import("std");
const middleware = @import("../middleware.zig");
const source_namespace = @import("root.zig");
session: FakeSession,
request_done: *std.Io.Queue(u8),
event_count: std.atomic.Value(u32) = .init(0),
request_phase: ?middleware.Phase = null,
decode_failures: u8 = 0,
settlements: u8 = 0,

pub fn io(_: *IntegrationContext) std.Io {
    return std.testing.io;
}

pub fn relayRequest(context: *IntegrationContext, settings: *source_namespace.Settings) source_namespace.Stats {
    const stats = source_namespace.relay(&context.session, source_namespace.relayOptions(.request, settings, .{ .dialect = .anthropic_messages }), context);
    context.request_done.putOneUncancelable(std.testing.io, 0) catch unreachable;
    return stats;
}

pub fn relayResponse(context: *IntegrationContext, settings: *source_namespace.Settings) source_namespace.Stats {
    _ = context.request_done.getOne(std.testing.io) catch return .{ .decode_failed = true };
    return source_namespace.relay(&context.session, source_namespace.relayOptions(.response, settings, .{ .dialect = .anthropic_messages }), context);
}

pub fn recordDecodeFailure(context: *IntegrationContext, _: source_namespace.Direction) void {
    context.decode_failures += 1;
}

pub fn settle(context: *IntegrationContext) void {
    context.settlements += 1;
}

pub fn emit(context: *IntegrationContext, event: source_namespace.Event) void {
    _ = context.event_count.fetchAdd(1, .monotonic);

    switch (event) {
        .lifecycle => |observed| if (observed.stream_id == 1) {
            context.request_phase = observed.phase;
        },
        .request_headers, .request_body, .request_finished, .response_headers, .response_body => {},
    }
}
