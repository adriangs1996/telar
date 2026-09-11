const Fuzzer = @This();
const source_namespace = @import("build.zig");
const Seed = @import("Seed.zig");
name: []const u8,
source: []const u8,
module: source_namespace.ModuleKind,
seeds: []const Seed,
