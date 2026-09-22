const data = @import("model");
const core = @import("telar-core");
const Metrics = @import("Metrics.zig");
const std = @import("std");
const State = @This();

pub const buffer_size = 8192;

metrics: Metrics,
sink: core.Sink,
buffer: [buffer_size]u8 = undefined,
write_pending: bool = false,
enabled: bool,

/// Creates the client's fail-closed diagnostics sink and metrics epoch.
///
/// ```zig
/// var telemetry = State.init(io, runtime_endpoint);
/// ```
pub fn init(io: std.Io, endpoint: []const u8) State {
    if (!core.enabled or endpoint.len == 0) {
        return .{
            .metrics = .{ .started_ns = core.now(io) },
            .sink = .{},
            .enabled = false,
        };
    }

    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "client-{d}", .{std.c.getpid()}) catch "client";
    var sink = core.Sink.init(io, endpoint, suffix);

    return .{
        .metrics = .{ .started_ns = core.now(io) },
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

/// Records a decoded message before the client rearms its borrowed receive buffer.
/// Example: `telemetry.recordMessage(received);`
pub fn recordMessage(self: *State, observation: *const data.RuntimeMessage) void {
    if (comptime !core.enabled) {
        return;
    }

    self.metrics.server_messages += 1;
    self.metrics.server_bytes += observation.payload_len;

    switch (observation.message) {
        .graphics_snapshot,
        .graphics_image,
        .graphics_shared_image,
        .graphics_image_chunk,
        .graphics_placement,
        .graphics_delete_image,
        .graphics_delete_placement,
        => {
            self.metrics.graphics_messages += 1;
            self.metrics.graphics_bytes += observation.payload_len;
        },
        else => {},
    }

    self.metrics.decode.observe(observation.decode_ns);
}
