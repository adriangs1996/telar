//! Every limit one source reached: how often, the last amount asked for,
//! the route that caught it, when, and when it was last shown or reported.
//! One row per limit name. The table has fixed capacity and lives in its
//! process model; it owns only its rows and index. What a reach does to a
//! row is `limit_reached.record`.
const std = @import("std");
const GenericSlotIndex = @import("GenericSlotIndex.zig").Type;
const Limit = @import("Limit.zig");
const LimitReach = @import("LimitReach.zig");
const LimitReaches = @This();

/// Distinct limits one table remembers. A new limit past this replaces the
/// one reached longest ago and counts in `evicted`.
pub const capacity = 128;
/// Index keys one name may take: a name whose hash collides with another's
/// takes the next, so two names never share a row.
const key_attempts = 4;

comptime {
    // The index stores a slot in one byte.
    std.debug.assert(capacity <= std.math.maxInt(u8));
}

/// An empty table, for a reader with nothing to list.
pub const none: LimitReaches = .{};

name: [capacity][Limit.max_name_bytes]u8 = undefined,
name_len: [capacity]u8 = undefined,
noun: [capacity][Limit.max_noun_bytes]u8 = undefined,
noun_len: [capacity]u8 = undefined,
route: [capacity][LimitReach.max_route_bytes]u8 = undefined,
route_len: [capacity]u8 = undefined,
value: [capacity]u64 = undefined,
requested: [capacity]?u64 = undefined,
hits: [capacity]u64 = undefined,
/// Wall clock of the last reach, in milliseconds since the epoch.
last_ms: [capacity]i64 = undefined,
/// Monotonic milliseconds of the last notice and the last report.
shown_ms: [capacity]?i64 = undefined,
reported_ms: [capacity]?i64 = undefined,
unreported: [capacity]u32 = undefined,
/// The index key each row holds.
key: [capacity]u64 = undefined,
index: GenericSlotIndex(2 * capacity) = .{},
count: usize = 0,
/// Rows replaced by newer limits since the table was made.
evicted: u64 = 0,

/// The row of one limit name, if it was reached.
/// Example: `const slot = reaches.find("bars.max_bar_actions") orelse return;`
pub fn find(self: *const LimitReaches, name: []const u8) ?usize {
    for (0..key_attempts) |attempt| {
        const slot = self.index.get(keyFor(name, attempt)) orelse continue;
        if (std.mem.eql(u8, self.nameAt(slot), name)) {
            return slot;
        }
    }

    return null;
}

/// Adds an empty row for a name `find` did not find, replacing the row
/// reached longest ago when the table is full.
/// Example: `const slot = reaches.find(name) orelse reaches.insert(name);`
pub fn insert(self: *LimitReaches, name: []const u8) usize {
    std.debug.assert(name.len <= Limit.max_name_bytes);

    var slot = self.count;
    if (self.count < capacity) {
        self.count += 1;
    } else {
        slot = self.oldest();
        self.index.remove(self.key[slot]);
        self.evicted +|= 1;
    }

    @memcpy(self.name[slot][0..name.len], name);
    self.name_len[slot] = @intCast(name.len);
    self.noun_len[slot] = 0;
    self.route_len[slot] = 0;
    self.value[slot] = 0;
    self.requested[slot] = null;
    self.hits[slot] = 0;
    self.last_ms[slot] = 0;
    self.shown_ms[slot] = null;
    self.reported_ms[slot] = null;
    self.unreported[slot] = 0;
    self.key[slot] = self.freeKey(name);
    self.index.put(self.key[slot], slot);
    return slot;
}

/// The reach a row last recorded, borrowing the row's bytes.
/// Example: `const reach = reaches.reachAt(slot);`
pub fn reachAt(self: *const LimitReaches, slot: usize) LimitReach {
    return .{
        .limit = .{
            .name = self.nameAt(slot),
            .noun = self.noun[slot][0..self.noun_len[slot]],
            .value = self.value[slot],
        },
        .requested = self.requested[slot],
        .route = self.route[slot][0..self.route_len[slot]],
    };
}

fn nameAt(self: *const LimitReaches, slot: usize) []const u8 {
    return self.name[slot][0..self.name_len[slot]];
}

fn oldest(self: *const LimitReaches) usize {
    var found: usize = 0;
    for (1..self.count) |slot| {
        if (self.last_ms[slot] < self.last_ms[found]) {
            found = slot;
        }
    }

    return found;
}

/// The first key of a name no row holds. Every attempt taken by another
/// name takes four 64-bit collisions, which a few hundred names never make.
fn freeKey(self: *const LimitReaches, name: []const u8) u64 {
    for (0..key_attempts) |attempt| {
        const candidate = keyFor(name, attempt);
        if (self.index.get(candidate) == null) {
            return candidate;
        }
    }

    unreachable;
}

fn keyFor(name: []const u8, attempt: usize) u64 {
    const hash = std.hash.Wyhash.hash(attempt, name);
    return if (hash == GenericSlotIndex(2 * capacity).empty_key) 1 else hash;
}

test "a full table replaces the limit reached longest ago and counts it" {
    var reaches: LimitReaches = .{};
    var name_buffer: [16]u8 = undefined;
    for (0..capacity) |number| {
        const name = try std.fmt.bufPrint(&name_buffer, "limit.{d}", .{number});
        const slot = reaches.insert(name);
        reaches.last_ms[slot] = @intCast(number + 10);
    }

    const slot = reaches.insert("limit.new");
    try std.testing.expectEqual(@as(usize, capacity), reaches.count);
    try std.testing.expectEqual(@as(u64, 1), reaches.evicted);
    try std.testing.expectEqual(slot, reaches.find("limit.new").?);
    try std.testing.expectEqual(@as(?usize, null), reaches.find("limit.0"));
    try std.testing.expect(reaches.find("limit.1") != null);
    try std.testing.expectEqualStrings("limit.new", reaches.reachAt(slot).limit.name);
}

test "names whose keys collide keep their own rows" {
    var reaches: LimitReaches = .{};
    const first = reaches.insert("render.retained_max_cells");

    // Point the second name's first key at the first row, as a hash
    // collision would, then add the second name.
    reaches.index.put(keyFor("gui.widgets.registry_capacity", 0), first);
    try std.testing.expectEqual(@as(?usize, null), reaches.find("gui.widgets.registry_capacity"));
    const second = reaches.insert("gui.widgets.registry_capacity");

    try std.testing.expect(first != second);
    try std.testing.expectEqual(first, reaches.find("render.retained_max_cells").?);
    try std.testing.expectEqual(second, reaches.find("gui.widgets.registry_capacity").?);
}
