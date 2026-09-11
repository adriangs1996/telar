const build = @import("../build.zig");
const Seed = @import("Seed.zig");
const Fuzzer = @This();

name: []const u8,
source: []const u8,
module: build.ModuleKind,
seeds: []const Seed,
