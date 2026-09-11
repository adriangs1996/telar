/// Deterministic integration seam proving that PTY input remains independent
/// while a pane's bounded ingest actor is occupied. Production entrypoints do
/// not install this gate.
const IngestTestGate = @This();
const source_namespace = @import("config.zig");
const std = @import("std");
entered: *source_namespace.Io.Queue(u8),
release: *source_namespace.Io.Queue(u8),
claimed: std.atomic.Value(bool) = .init(false),

/// Blocks only the first caller until the test releases it.
///
/// ```zig
/// try gate.wait(std.testing.io);
/// ```
pub fn wait(gate: *IngestTestGate, io: source_namespace.Io) !void {
    if (gate.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }

    try gate.entered.putOne(io, 0);
    _ = try gate.release.getOne(io);
}
