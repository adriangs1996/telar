//! The client's diagnostics: its counters, the fail-closed sink and the one
//! line `client_telemetry` hands a worker to write.
const data = @import("model");
const core = @import("telar-core");
const Metrics = @import("Metrics.zig");
const std = @import("std");
const State = @This();

pub const buffer_size = 8192;

metrics: Metrics,
sink: core.Sink,
// SAFETY: client_telemetry formats a complete line before setting line_len and queuing its write; writes expose only that initialized prefix.
buffer: [buffer_size]u8 = undefined,
/// The formatted line in `buffer` a write job borrows while `write_pending`.
line_len: usize = 0,
write_pending: bool = false,
enabled: bool,

/// Creates the client's fail-closed diagnostics sink and metrics epoch.
///
/// ```zig
/// var telemetry = State.init(io, runtime_endpoint);
/// ```
pub fn init(io: std.Io, endpoint: []const u8) State {
    if (endpoint.len != 0) {
        core.Sink.removeOrphans(io, endpoint);
    }

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
pub fn deinit(self: *State, io: std.Io) void {
    self.write_pending = false;
    self.enabled = false;
    self.sink.deinit(io);
}

/// Example: `if (!telemetry.available()) return;`
pub fn available(self: *const State) bool {
    return self.enabled and self.sink.available();
}

/// Takes the single write token, or reports that a write is in flight.
/// Example: `if (!telemetry.reserveWrite()) return;`
pub fn reserveWrite(self: *State) bool {
    if (!self.available() or self.write_pending) {
        return false;
    }

    self.write_pending = true;

    return true;
}

/// Stops later observations; a write in flight keeps the sink until it ends.
/// Example: `telemetry.disable(io);`
pub fn disable(self: *State, io: std.Io) void {
    self.enabled = false;

    if (!self.write_pending) {
        self.sink.deinit(io);
    }
}

/// Returns the write token. A failed write disables the sink, and a sink
/// disabled while the write ran closes now.
/// Example: `telemetry.finishWrite(io, result);`
pub fn finishWrite(self: *State, io: std.Io, result: anyerror!void) void {
    self.write_pending = false;
    result catch {
        self.enabled = false;
    };

    if (!self.enabled) {
        self.sink.deinit(io);
    }
}

/// The line a write job appends to the sink.
/// Example: `try telemetry.write(io);`
pub fn write(self: *State, io: std.Io) anyerror!void {
    try self.sink.write(io, self.buffer[0..self.line_len]);
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
