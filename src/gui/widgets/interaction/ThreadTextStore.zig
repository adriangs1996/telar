//! Lazily owned, double-buffered text geometry for the native reader.
allocator: @import("std").mem.Allocator,
maps: @import("../../render/GenericPresentedState.zig").Type(@import("ThreadTextGeometry.zig")) = .{},
