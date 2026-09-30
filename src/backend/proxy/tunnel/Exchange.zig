//! What one authenticated CONNECT exchange knows about itself: the counters
//! it reports to, its connection number and row, the protocol it negotiated
//! and the host it reached. Capture borrows these for every half it starts.
const std = @import("std");
const Connections = @import("../Connections.zig");
const Counters = @import("../Counters.zig");
const Protocol = @import("../Protocol.zig").Protocol;
const metrics = @import("../metrics.zig");
const Exchange = @This();

io: std.Io,
telemetry: *Counters,
connection_id: u64,
protocol: Protocol,
host: std.Io.net.HostName = undefined,
/// The connection's row; null in tests that relay without admission.
connections: ?*Connections = null,
slot: Connections.Slot = undefined,

/// Records one outcome detected by a protocol adapter.
///
/// ```zig
/// exchange.record(.h2_decode_failure);
/// ```
pub fn record(self: *Exchange, counter: metrics.Counter) void {
    self.telemetry.record(counter);
}

/// Records that bytes moved, so a busy connection is never taken for idle.
///
/// ```zig
/// exchange.touch();
/// ```
pub fn touch(self: *Exchange) void {
    const connections = self.connections orelse return;
    connections.touch(self.slot, std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
}

/// Moves the connection to its next phase.
///
/// ```zig
/// exchange.enter(.idle);
/// ```
pub fn enter(self: *Exchange, phase: Connections.Phase) void {
    const connections = self.connections orelse return;
    connections.enter(self.slot, phase, std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
}
