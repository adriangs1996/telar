const std = @import("std");
/// Deterministic integration seam: holds the first admitted connection's
/// tunnel in a wait that neither a socket shutdown nor a cancellation
/// interrupts, as the system resolver does, until the test releases it.
/// Production entrypoints do not install this gate.
const TunnelTestGate = @This();

/// Set once the first tunnel is held.
held: std.Io.Event = .unset,
/// Set by the test to let the held tunnel go on.
released: std.Io.Event = .unset,
claimed: std.atomic.Value(bool) = .init(false),

/// Blocks only the first caller until the test releases it.
///
/// ```zig
/// gate.hold(std.testing.io);
/// ```
pub fn hold(self: *TunnelTestGate, io: std.Io) void {
    if (self.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }

    self.held.set(io);
    self.released.waitUncancelable(io);
}
