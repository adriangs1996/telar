const FakeSession = @import("FakeSession.zig");
const std = @import("std");
const middleware = @import("../middleware.zig");
const SettingsType = @import("Settings.zig");
const StatsType = @import("Stats.zig");
const h2 = @import("h2.zig");
const relay_module = @import("relay.zig");
const IntegrationContext = @This();

session: FakeSession,
request_done: *std.Io.Queue(u8),
event_count: std.atomic.Value(u32) = .init(0),
request_phase: ?middleware.Phase = null,
decode_failures: u8 = 0,
settlements: u8 = 0,

pub fn io(_: *IntegrationContext) std.Io {
    return std.testing.io;
}

pub fn relayRequest(context: *IntegrationContext, settings: *SettingsType) StatsType {
    const stats = h2.relay(&context.session, h2.relayOptions(.request, settings, .{ .dialect = .anthropic_messages }), context);
    context.request_done.putOneUncancelable(std.testing.io, 0) catch unreachable;
    return stats;
}

pub fn relayResponse(context: *IntegrationContext, settings: *SettingsType) StatsType {
    _ = context.request_done.getOne(std.testing.io) catch return .{ .decode_failed = true };
    return h2.relay(&context.session, h2.relayOptions(.response, settings, .{ .dialect = .anthropic_messages }), context);
}

pub fn recordDecodeFailure(context: *IntegrationContext, _: relay_module.Direction) void {
    context.decode_failures += 1;
}

pub fn settle(context: *IntegrationContext) void {
    context.settlements += 1;
}

pub fn emit(context: *IntegrationContext, event: relay_module.Event) void {
    _ = context.event_count.fetchAdd(1, .monotonic);

    switch (event) {
        .lifecycle => |observed| if (observed.stream_id == 1) {
            context.request_phase = observed.phase;
        },
        .request_headers, .request_body, .request_finished, .response_headers, .response_body => {},
    }
}
