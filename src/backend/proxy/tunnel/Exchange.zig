//! What one authenticated CONNECT exchange knows about itself: the counters
//! it reports to, its connection number, the protocol it negotiated and the
//! host it reached. Capture borrows these for every half it starts.
const std = @import("std");
const Counters = @import("../Counters.zig");
const Protocol = @import("../Protocol.zig").Protocol;
const metrics = @import("../metrics.zig");
const Exchange = @This();

io: std.Io,
telemetry: *Counters,
connection_id: u64,
protocol: Protocol,
host: std.Io.net.HostName = undefined,

/// Records one outcome detected by a protocol adapter.
///
/// ```zig
/// exchange.record(.h2_decode_failure);
/// ```
pub fn record(self: *Exchange, counter: metrics.Counter) void {
    self.telemetry.record(counter);
}
