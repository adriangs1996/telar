//! Lazily owned, double-buffered text geometry for the native reader.
const std = @import("std");
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const ThreadTextGeometry = @import("ThreadTextGeometry.zig");
allocator: std.mem.Allocator,
maps: GenericPresentedState(ThreadTextGeometry) = .{},
