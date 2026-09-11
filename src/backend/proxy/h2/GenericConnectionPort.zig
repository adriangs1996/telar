const std = @import("std");
const Settings = @import("Settings.zig");
const StatsType = @import("Stats.zig");
const relay = @import("relay.zig");

/// Supplies both directional relays and the effects produced when they stop.
///
/// ```zig
/// const port: ConnectionPort(Context) = .{
///     .io = Context.io,
///     .relay_request = Context.relayRequest,
///     .relay_response = Context.relayResponse,
///     .record_decode_failure = Context.recordDecodeFailure,
///     .settle = Context.settle,
/// };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        io: *const fn (*Context) std.Io,
        relay_request: *const fn (*Context, *Settings) StatsType,
        relay_response: *const fn (*Context, *Settings) StatsType,
        record_decode_failure: *const fn (*Context, relay.Direction) void,
        settle: *const fn (*Context) void,
    };
}
