const State = @This();
const Metrics = @import("Metrics.zig");
const source_namespace = @import("telemetry.zig");
const std = @import("std");
metrics: Metrics,
sink: source_namespace.diagnostics.Sink,
buffer: [source_namespace.buffer_size]u8 = undefined,
write_pending: bool = false,
enabled: bool,

/// Creates the client's fail-closed diagnostics sink and metrics epoch.
///
/// ```zig
/// var telemetry = State.init(io, runtime_endpoint);
/// ```
pub fn init(io: source_namespace.Io, endpoint: []const u8) State {
    if (!source_namespace.diagnostics.enabled or endpoint.len == 0) {
        return .{
            .metrics = .{ .started_ns = source_namespace.diagnostics.now(io) },
            .sink = .{},
            .enabled = false,
        };
    }

    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "client-{d}", .{std.c.getpid()}) catch "client";
    var sink = source_namespace.diagnostics.Sink.init(io, endpoint, suffix);

    return .{
        .metrics = .{ .started_ns = source_namespace.diagnostics.now(io) },
        .sink = sink,
        .enabled = sink.available(),
    };
}

/// Closes the diagnostics sink after the client has cancelled its tasks.
///
/// ```zig
/// telemetry.deinit(io);
/// ```
pub fn deinit(state: *State, io: source_namespace.Io) void {
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

pub fn disable(state: *State, io: source_namespace.Io) void {
    state.enabled = false;

    if (!state.write_pending) {
        state.sink.deinit(io);
    }
}
