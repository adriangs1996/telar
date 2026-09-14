//! Stable atlas-local identities; a glyph index is meaningful only within its face.
const std = @import("std");

pub const Id = enum(u4) {
    primary,
    text,
    symbols,
    sans,
    sans_semibold,
    fallback_0,
    fallback_1,
    fallback_2,
    fallback_3,
    fallback_4,
    fallback_5,
    fallback_6,
    fallback_7,

    /// Discovered installed faces the set may hold at once; slot numbers
    /// map onto `fallback_0..fallback_7`.
    pub const fallback_slots = 8;

    /// The identity of a discovered pool slot.
    /// Example: `const id = Id.fallback(2);`
    pub fn fallback(slot: u3) Id {
        return @enumFromInt(@intFromEnum(Id.fallback_0) + @as(u4, slot));
    }

    /// The pool slot behind a discovered identity; null for every embedded
    /// or configured face. Example: `if (id.fallbackSlot()) |slot| { ... }`
    pub fn fallbackSlot(id: Id) ?u3 {
        const raw = @intFromEnum(id);
        if (raw < @intFromEnum(Id.fallback_0)) {
            return null;
        }

        return @intCast(raw - @intFromEnum(Id.fallback_0));
    }

    /// Fallback ink is fitted into the requesting cell; natural faces keep
    /// their own advances and bearings. Example: `if (id.fitted()) { ... }`
    pub fn fitted(id: Id) bool {
        return id == .text or id == .symbols or id.fallbackSlot() != null;
    }
};

comptime {
    std.debug.assert(@intFromEnum(Id.fallback_7) - @intFromEnum(Id.fallback_0) + 1 == Id.fallback_slots);
}

test "fallback identities round-trip their slot and are fitted" {
    for (0..Id.fallback_slots) |slot| {
        const id = Id.fallback(@intCast(slot));
        try std.testing.expectEqual(@as(?u3, @intCast(slot)), id.fallbackSlot());
        try std.testing.expect(id.fitted());
    }

    try std.testing.expectEqual(@as(?u3, null), Id.sans.fallbackSlot());
    try std.testing.expect(!Id.primary.fitted());
}
