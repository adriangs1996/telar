const Transformation = @This();
const std = @import("std");
const HeaderSnapshot = @import("HeaderSnapshot.zig");
const EffectBatch = @import("EffectBatch.zig");
io: std.Io,
snapshot: HeaderSnapshot,
effects: *EffectBatch,
