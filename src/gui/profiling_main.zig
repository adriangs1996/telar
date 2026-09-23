//! Offline CPU workloads. This executable does not open a native window.
const std = @import("std");
const core = @import("telar-core");
const options = @import("profile_options");
const Probe = @import("ProfilingProbe.zig");

pub const telar_profile_counts = options.profile_counts;
pub const telar_profile_timing = options.profile_timing;
pub var profile_store: if (core.profiling.active) core.ProfileStore else void = if (core.profiling.active) .{} else {};

/// Run fixed CPU workloads: `telar-dod-probe > measurements.jsonl`.
pub fn main(init: std.process.Init) !void {
    defer if (comptime core.profiling.active) {
        if (init.environ_map.get("TELAR_PROFILE_DIR")) |directory| {
            profile_store.dump(init.io, directory) catch {};
        }
    };
    var buffer: [16384]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var probe: Probe = .{ .io = init.io, .gpa = init.gpa, .writer = &output.interface };
    probe.terminal_only = init.environ_map.get("DOD_TERMINAL_ONLY") != null;
    probe.agent_only = init.environ_map.get("DOD_AGENT_ONLY") != null;
    probe.terminal_mode = init.environ_map.get("DOD_MODE");
    probe.verify = init.environ_map.get("DOD_VERIFY") != null;
    if (init.environ_map.get("DOD_SAMPLES")) |value| {
        probe.sample_count = try std.fmt.parseInt(usize, value, 10);
    }
    if (init.environ_map.get("DOD_WARMUP")) |value| {
        probe.warmup_count = try std.fmt.parseInt(usize, value, 10);
    }
    if (init.environ_map.get("DOD_WARMUP_NS")) |value| {
        probe.warmup_ns = try std.fmt.parseInt(u64, value, 10);
    }
    try probe.run();
    try output.interface.flush();
}
