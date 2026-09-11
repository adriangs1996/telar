const std = @import("std");
/// Deterministic integration seam proving that PTY input remains independent
/// while a pane's bounded ingest actor is occupied. Production entrypoints do
/// not install this gate.
const IngestTestGate = @This();

entered: *std.Io.Queue(u8),
release: *std.Io.Queue(u8),
claimed: std.atomic.Value(bool) = .init(false),

/// Blocks only the first caller until the test releases it.
///
/// ```zig
/// try gate.wait(std.testing.io);
/// ```
pub fn wait(gate: *IngestTestGate, io: std.Io) !void {
    if (gate.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }

    try gate.entered.putOne(io, 0);
    _ = try gate.release.getOne(io);
}
