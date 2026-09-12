const std = @import("std");

// Root fuzz instrumentation also reaches linked C-family sources. zcov's
// runtime does not provide every callback those sources emit, so keep native
// dependencies outside the coverage graph.
const no_c_coverage = "-fno-sanitize-coverage=trace-pc-guard,trace-cmp,inline-8bit-counters,pc-table";

pub fn forCoverage(b: *std.Build, base: []const []const u8, disable_coverage: bool) []const []const u8 {
    if (!disable_coverage) {
        return base;
    }
    const flags = b.allocator.alloc([]const u8, base.len + 1) catch @panic("OOM");
    @memcpy(flags[0..base.len], base);
    flags[base.len] = no_c_coverage;
    return flags;
}
