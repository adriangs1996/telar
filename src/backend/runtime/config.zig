//! Public construction contract and opt-in integration seams for a runtime.

const std = @import("std");
const IngestTestGate = @import("IngestTestGate.zig");

test "the ingest gate is claimed at most once" {
    var entered_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var entered: std.Io.Queue(u8) = .init(&entered_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var gate: IngestTestGate = .{ .entered = &entered, .release = &release };

    gate.claimed.store(true, .release);
    try gate.wait(std.testing.io);

    try std.testing.expect(gate.claimed.load(.acquire));
}
