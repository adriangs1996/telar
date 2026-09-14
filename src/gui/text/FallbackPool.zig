//! At most eight discovered faces for one font set. Slots are filled in
//! order and never evicted: a shaped run cached against slot N keeps
//! meaning the same face until the set is rebuilt with the font. A full
//! pool refuses further faces; their graphemes keep the replacement glyph.
const std = @import("std");
const FallbackFace = @import("FallbackFace.zig");
const FontFace = @import("FontFace.zig");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const Id = @import("font_id.zig").Id;
const FallbackPool = @This();

pub const capacity = Id.fallback_slots;

faces: [capacity]?FallbackFace = @splat(null),
count: u8 = 0,

pub fn deinit(pool: *FallbackPool, allocator: std.mem.Allocator) void {
    for (&pool.faces) |*slot| {
        if (slot.*) |*face| {
            face.deinit(allocator);
        }

        slot.* = null;
    }

    pool.count = 0;
}

/// Whether another face can join. Example: `if (pool.full()) { ... }`
pub fn full(pool: *const FallbackPool) bool {
    return pool.count == capacity;
}

/// The slot already holding `match`, so one file is never loaded twice.
/// Example: `if (pool.find(match)) |slot| { ... }`
pub fn find(pool: *const FallbackPool, match: FontMatch) ?u3 {
    for (pool.faces[0..pool.count], 0..) |slot, index| {
        if (slot.?.matches(match)) {
            return @intCast(index);
        }
    }

    return null;
}

/// Takes ownership of `face` in the next free slot; null when full, and the
/// caller keeps the face. Example: `const slot = pool.add(face) orelse ...;`
pub fn add(pool: *FallbackPool, face: FallbackFace) ?u3 {
    if (pool.full()) {
        return null;
    }

    const slot: u3 = @intCast(pool.count);
    pool.faces[slot] = face;
    pool.count += 1;
    return slot;
}

/// The face in a filled slot. Example: `const face = pool.get(0);`
pub fn get(pool: *FallbackPool, slot: u3) *FontFace {
    return &pool.faces[slot].?.face;
}

/// The first filled slot covering the whole grapheme, in discovery order.
/// Example: `if (pool.covering("\u{23f5}")) |slot| { ... }`
pub fn covering(pool: *const FallbackPool, text: []const u8) ?u3 {
    for (pool.faces[0..pool.count], 0..) |slot, index| {
        if (slot.?.face.covers(text)) {
            return @intCast(index);
        }
    }

    return null;
}
