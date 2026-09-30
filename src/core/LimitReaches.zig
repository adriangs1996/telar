//! Every limit one process reached: how often, the last amount asked for,
//! when, and when it was last shown or reported. One row per limit name.
//! The table has fixed capacity and lives in its process model, so
//! recording a reach is one index probe and allocates nothing.
const std = @import("std");
const GenericSlotIndex = @import("GenericSlotIndex.zig").Type;
const Limit = @import("Limit.zig");
const LimitReach = @import("LimitReach.zig");
const LimitOrigin = @import("LimitOrigin.zig").LimitOrigin;
const RecordedReach = @import("RecordedReach.zig");
const LimitReaches = @This();

/// Distinct limits one process remembers. A new limit past this replaces
/// the one reached longest ago.
pub const capacity = 64;
/// A limit is shown again only after this long; reaches in between count.
pub const show_interval_ms: i64 = 60 * std.time.ms_per_s;
/// A client folds its reaches into one report to the runtime this often.
pub const report_interval_ms: i64 = std.time.ms_per_s;

name: [capacity][Limit.max_name_bytes]u8 = undefined,
name_len: [capacity]u8 = undefined,
noun: [capacity][Limit.max_noun_bytes]u8 = undefined,
noun_len: [capacity]u8 = undefined,
value: [capacity]u64 = undefined,
requested: [capacity]?u64 = undefined,
origin: [capacity]LimitOrigin = undefined,
hits: [capacity]u64 = undefined,
last_ms: [capacity]i64 = undefined,
shown_ms: [capacity]?i64 = undefined,
reported_ms: [capacity]?i64 = undefined,
unreported: [capacity]u32 = undefined,
index: GenericSlotIndex(2 * capacity) = .{},
count: usize = 0,

/// Counts `hits` reaches of one limit at `now_ms` (wall clock) and decides
/// whether to show it. A name longer than a row holds is cut to fit.
///
/// ```zig
/// const recorded = model.limit_reaches.record(reach, .runtime, now_ms, 1);
/// if (recorded.show) { ... }
/// ```
pub fn record(self: *LimitReaches, reach: LimitReach, origin: LimitOrigin, now_ms: i64, hits: u32) RecordedReach {
    const name = reach.limit.name[0..@min(reach.limit.name.len, Limit.max_name_bytes)];
    const slot = self.find(name) orelse self.add(name, origin);

    const noun = reach.limit.noun[0..@min(reach.limit.noun.len, Limit.max_noun_bytes)];
    @memcpy(self.noun[slot][0..noun.len], noun);
    self.noun_len[slot] = @intCast(noun.len);
    self.value[slot] = reach.limit.value;
    if (reach.requested) |requested| {
        self.requested[slot] = requested;
    }

    self.hits[slot] +|= hits;
    self.unreported[slot] +|= hits;
    self.last_ms[slot] = now_ms;

    const show = if (self.shown_ms[slot]) |shown| now_ms - shown >= show_interval_ms or now_ms < shown else true;
    if (show) {
        self.shown_ms[slot] = now_ms;
    }

    return .{
        .slot = slot,
        .show = show,
    };
}

/// Takes the reaches of one row not yet reported to the runtime, at most
/// once per `report_interval_ms`; null while the interval runs.
///
/// ```zig
/// if (model.limit_reaches.takeReport(slot, now_ms)) |hits| { ... }
/// ```
pub fn takeReport(self: *LimitReaches, slot: usize, now_ms: i64) ?u32 {
    if (self.unreported[slot] == 0) {
        return null;
    }

    if (self.reported_ms[slot]) |reported| {
        if (now_ms - reported < report_interval_ms and now_ms >= reported) {
            return null;
        }
    }

    const hits = self.unreported[slot];
    self.unreported[slot] = 0;
    self.reported_ms[slot] = now_ms;
    return hits;
}

/// Gives back reaches a report could not carry, so the next one does.
/// Example: `model.limit_reaches.restoreReport(slot, hits);`
pub fn restoreReport(self: *LimitReaches, slot: usize, hits: u32) void {
    self.unreported[slot] +|= hits;
    self.reported_ms[slot] = null;
}

/// The row of one limit name, if it was reached.
/// Example: `const slot = reaches.find("bars.max_bar_actions") orelse return;`
pub fn find(self: *const LimitReaches, name: []const u8) ?usize {
    const slot = self.index.get(key(name)) orelse return null;
    if (!std.mem.eql(u8, self.nameAt(slot), name)) {
        return null;
    }

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
    };
}

fn nameAt(self: *const LimitReaches, slot: usize) []const u8 {
    return self.name[slot][0..self.name_len[slot]];
}

fn add(self: *LimitReaches, name: []const u8, origin: LimitOrigin) usize {
    var slot = self.count;
    if (self.count < capacity) {
        self.count += 1;
    } else {
        slot = self.oldest();
        if (self.find(self.nameAt(slot)) == slot) {
            self.index.remove(key(self.nameAt(slot)));
        }
    }

    @memcpy(self.name[slot][0..name.len], name);
    self.name_len[slot] = @intCast(name.len);
    self.noun_len[slot] = 0;
    self.value[slot] = 0;
    self.requested[slot] = null;
    self.origin[slot] = origin;
    self.hits[slot] = 0;
    self.last_ms[slot] = 0;
    self.shown_ms[slot] = null;
    self.reported_ms[slot] = null;
    self.unreported[slot] = 0;

    // A second name with the same 64-bit hash gets a row the index cannot
    // find; over a few hundred names that does not happen in practice.
    if (self.index.get(key(name)) == null) {
        self.index.put(key(name), slot);
    }

    return slot;
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

fn key(name: []const u8) u64 {
    const hash = std.hash.Wyhash.hash(0, name);
    return if (hash == 0) 1 else hash;
}

fn sample(name: []const u8, requested: ?u64) LimitReach {
    return .{
        .limit = .{
            .name = name,
            .noun = "items",
            .value = 4,
        },
        .requested = requested,
    };
}

test "a limit is shown once per interval and every reach counts" {
    var reaches: LimitReaches = .{};

    const first = reaches.record(sample("bars.max_bar_actions", 5), .client, 1_000, 1);
    try std.testing.expect(first.show);

    const second = reaches.record(sample("bars.max_bar_actions", 17), .client, 2_000, 1);
    try std.testing.expect(!second.show);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[first.slot]);
    try std.testing.expectEqual(@as(?u64, 17), reaches.requested[first.slot]);
    try std.testing.expectEqual(@as(i64, 2_000), reaches.last_ms[first.slot]);

    const later = reaches.record(sample("bars.max_bar_actions", null), .client, 1_000 + show_interval_ms, 1);
    try std.testing.expect(later.show);
    try std.testing.expectEqual(@as(?u64, 17), reaches.requested[first.slot]);
    try std.testing.expectEqual(@as(u64, 3), reaches.hits[first.slot]);
}

test "reports fold reaches and wait for their interval" {
    var reaches: LimitReaches = .{};
    const slot = reaches.record(sample("gui.widgets.registry_capacity", null), .client, 0, 1).slot;

    try std.testing.expectEqual(@as(?u32, 1), reaches.takeReport(slot, 0));
    _ = reaches.record(sample("gui.widgets.registry_capacity", null), .client, 10, 1);
    _ = reaches.record(sample("gui.widgets.registry_capacity", null), .client, 20, 1);
    try std.testing.expectEqual(@as(?u32, null), reaches.takeReport(slot, 20));
    try std.testing.expectEqual(@as(?u32, 2), reaches.takeReport(slot, report_interval_ms));

    reaches.restoreReport(slot, 2);
    try std.testing.expectEqual(@as(?u32, 2), reaches.takeReport(slot, report_interval_ms + 1));
}

test "a full table replaces the limit reached longest ago" {
    var reaches: LimitReaches = .{};
    var name_buffer: [16]u8 = undefined;
    for (0..capacity) |number| {
        const name = try std.fmt.bufPrint(&name_buffer, "limit.{d}", .{number});
        _ = reaches.record(sample(name, null), .runtime, @intCast(number + 10), 1);
    }

    const slot = reaches.record(sample("limit.new", null), .runtime, 1_000, 1).slot;
    try std.testing.expectEqual(@as(usize, capacity), reaches.count);
    try std.testing.expectEqual(slot, reaches.find("limit.new").?);
    try std.testing.expectEqual(@as(?usize, null), reaches.find("limit.0"));
    try std.testing.expect(reaches.find("limit.1") != null);
    try std.testing.expectEqualStrings("limit.new", reaches.reachAt(slot).limit.name);
}
