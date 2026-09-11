const std = @import("std");
const HeaderSnapshot = @import("HeaderSnapshot.zig");
const EffectBatch = @import("EffectBatch.zig");
const Transformation = @This();

io: std.Io,
snapshot: HeaderSnapshot,
effects: *EffectBatch,
