const Metrics = @import("Metrics.zig");
const SinkType = @import("telar-core").Sink;
const std = @import("std");
const enabled_module = @import("telar-core").enabled;
const now_module = @import("telar-core").now;
const State = @This();

pub const buffer_size = 8192;

metrics: Metrics,
sink: SinkType,
buffer: [buffer_size]u8 = undefined,
write_pending: bool = false,
enabled: bool,

/// Creates the client's fail-closed diagnostics sink and metrics epoch.
///
/// ```zig
/// var telemetry = State.init(io, runtime_endpoint);
/// ```
pub fn init(io: std.Io, endpoint: []const u8) State {
    if (!enabled_module or endpoint.len == 0) {
        return .{
            .metrics = .{ .started_ns = now_module(io) },
            .sink = .{},
            .enabled = false,
        };
    }

    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "client-{d}", .{std.c.getpid()}) catch "client";
    var sink = SinkType.init(io, endpoint, suffix);

    return .{
        .metrics = .{ .started_ns = now_module(io) },
        .sink = sink,
        .enabled = sink.available(),
    };
}

/// Closes the diagnostics sink after the client has cancelled its tasks.
///
/// ```zig
/// telemetry.deinit(io);
/// ```
pub fn deinit(state: *State, io: std.Io) void {
    state.write_pending = false;
    state.enabled = false;
    state.sink.deinit(io);
}

pub fn available(state: *const State) bool {
    return state.enabled and state.sink.available();
}

pub fn reserveWrite(state: *State) bool {
    if (!state.available() or state.write_pending) {
        return false;
    }

    state.write_pending = true;

    return true;
}

pub fn disable(state: *State, io: std.Io) void {
    state.enabled = false;

    if (!state.write_pending) {
        state.sink.deinit(io);
    }
}
