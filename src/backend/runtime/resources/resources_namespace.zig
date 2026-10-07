//! Physical resources acquired and owned for one runtime lifetime.

const std = @import("std");
const core = @import("telar-core");
const State = @import("../observability/State.zig");

pub fn initTelemetry(io: std.Io, endpoint: []const u8) State {
    core.Sink.removeOrphans(io, endpoint);
    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "runtime-{d}", .{std.c.getpid()}) catch "runtime";
    return State.init(io, endpoint, suffix);
}
