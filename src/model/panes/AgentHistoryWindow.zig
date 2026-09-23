//! A bounded reading window retains visible history across asynchronous page loads.
const std = @import("std");
const core = @import("telar-core");
const Window = @This();

pub const max_scan_pages = 32;
pub const capacity = 16;

pages: [capacity]core.AgentHistoryPage = undefined,
gaps: [capacity]?@import("AgentHistoryGap.zig") = @splat(null),
count: u8 = 0,
generation: u64 = 0,
revision: u64 = 1,
live_revision: u64 = 0,
pending: ?core.agent_history.Direction = null,
direction: core.agent_history.Direction = .older,
failed: bool = false,
failure_text: [256]u8 = undefined,
failure_len: u16 = 0,
replace_seam: bool = false,
retained: bool = false,
selection_only: bool = false,
preserve_seam: bool = false,
scan_remaining: u8 = max_scan_pages,

/// Freezes the live seam before an asynchronous history request starts.
/// Example: `window.start(live, generation);`
pub fn start(self: *Window, live: *const core.AgentThreadSnapshot, generation: u64) void {
    self.* = .{ .generation = generation, .count = 1, .live_revision = live.revision };
    self.pages[0] = .{ .request_id = @enumFromInt(0), .view_generation = generation, .snapshot = live.*, .has_before = true, .has_after = false };
    for (live.items()) |item| {
        self.replace_seam = self.replace_seam or !item.fragment_end;
    }
}

/// Returns one bounded request cursor without retaining provider buffers.
/// Example: `const cursor = window.cursor(.older);`
pub fn cursor(self: *const Window, direction: core.agent_history.Direction) []const u8 {
    return if (direction == .older) self.pages[0].before.slice() else self.pages[self.count - 1].after.slice();
}

/// Example: `if (window.has(.older)) showEarlier();`
pub fn has(self: *const Window, direction: core.agent_history.Direction) bool {
    return if (direction == .older) self.pages[0].has_before else self.pages[self.count - 1].has_after;
}

/// Keeps earlier context when the reader reaches the current live tail.
/// Example: `if (window.followLive(live)) invalidate();`
pub fn followLive(self: *Window, live: *const core.AgentThreadSnapshot) bool {
    if (self.live_revision == live.revision or self.retained or self.pending != null or self.has(.newer)) {
        return false;
    }

    const tail = &self.pages[self.count - 1];
    if (tail.before.len != 0 or tail.after.len != 0) {
        if (self.count == capacity) {
            self.discardBefore(1);
        }

        self.count += 1;
        self.gaps[self.count - 1] = null;
    }

    self.pages[self.count - 1] = .{ .request_id = @enumFromInt(0), .view_generation = self.generation, .snapshot = live.*, .has_before = true, .has_after = false };
    self.live_revision = live.revision;
    self.revision +%= 1;
    return true;
}

/// The first retained provider item anchors a cursorless initial request.
/// Example: `request.anchor = window.anchor();`
pub fn anchor(self: *const Window) []const u8 {
    const item = self.anchorItem() orelse return "";
    return item.sourceId(&self.pages[0].snapshot);
}

/// The anchor's turn disambiguates provider item IDs reused by later turns.
/// Example: `request.anchor_turn = window.anchorTurn();`
pub fn anchorTurn(self: *const Window) []const u8 {
    const item = self.anchorItem() orelse return "";
    return item.sourceTurn(&self.pages[0].snapshot);
}

fn anchorItem(self: *const Window) ?*const core.AgentThreadItem {
    if (self.replace_seam) {
        return null;
    }
    const snapshot = &self.pages[0].snapshot;
    for (snapshot.items()) |*item| {
        if (item.sourceId(snapshot).len > 0) {
            return if (item.complete and item.sourceTurn(snapshot).len > 0) item else null;
        }
    }

    return null;
}

/// Admits only the outstanding navigation generation, keeping the shared seam.
/// Example: `_ = window.apply(page);`
pub fn apply(self: *Window, page: *const core.AgentHistoryPage) bool {
    const direction = self.pending orelse return false;
    if (page.view_generation != self.generation) {
        return false;
    }

    const more = if (direction == .older) page.has_before else page.has_after;
    const next_cursor = if (direction == .older) page.before.slice() else page.after.slice();
    if (self.preserve_seam and more and std.mem.eql(u8, self.cursor(direction), next_cursor)) {
        self.fail("History cursor did not advance");
        self.scan_remaining = 0;
        self.revision +%= 1;
        return true;
    }

    self.pending = null;
    self.failed = false;
    if (page.snapshot.item_count == 0) {
        if (direction == .older) {
            self.pages[0].has_before = page.has_before;
            self.pages[0].before = page.before;
        } else {
            self.pages[self.count - 1].has_after = page.has_after;
            self.pages[self.count - 1].after = page.after;
        }
    } else if (self.replace_seam) {
        self.pages[0] = page.*;
        self.count = 1;
        self.gaps = @splat(null);
        self.replace_seam = false;
    } else if (self.preserve_seam and self.count > 1) {
        const edge: usize = if (direction == .older) 0 else self.count - 1;
        const removed = &self.pages[edge].snapshot;
        const key = groupKey(removed, &removed.items()[0]);
        self.pages[edge] = page.*;
        self.gaps[if (direction == .older) @as(usize, 1) else edge] = .{ .key = key, .direction = direction };
    } else if (direction == .older) {
        const count = @min(capacity, self.count + 1);
        var index: usize = count - 1;
        while (index > 0) : (index -= 1) {
            self.pages[index] = self.pages[index - 1];
            self.gaps[index] = self.gaps[index - 1];
        }
        self.pages[0] = page.*;
        self.gaps[0] = null;
        self.count = @intCast(count);
    } else {
        if (self.count == capacity) {
            self.discardBefore(1);
        }
        self.pages[self.count] = page.*;
        self.gaps[self.count] = null;
        self.count += 1;
    }

    self.preserve_seam = false;
    self.revision +%= 1;
    return true;
}

/// Reloads the omitted part of the selected work group from its retained boundary.
/// Example: `const direction = window.revealWork(group_key) orelse return;`
pub fn revealWork(self: *Window, key: u64) ?core.agent_history.Direction {
    for (self.gaps[0..self.count], 0..) |optional, index| {
        const gap = optional orelse continue;
        if (gap.key != key) {
            continue;
        }

        if (gap.direction == .older) {
            self.discardBefore(index);
        } else {
            self.count = @intCast(index);
        }
        self.preserve_seam = false;
        self.pending = null;
        self.failed = false;
        self.scan_remaining = max_scan_pages;
        self.revision +%= 1;
        return gap.direction;
    }

    return null;
}

fn discardBefore(self: *Window, count: usize) void {
    const remaining = self.count - count;
    for (0..remaining) |index| {
        self.pages[index] = self.pages[index + count];
        self.gaps[index] = self.gaps[index + count];
    }
    self.count = @intCast(remaining);
    self.gaps[0] = null;
}

/// Identifies a disclosure independently of page boundaries and item numbering.
/// Example: `const key = Window.groupKey(snapshot, item);`
pub fn groupKey(snapshot: *const core.AgentThreadSnapshot, item: *const core.AgentThreadItem) u64 {
    const turn = item.sourceTurn(snapshot);
    if (turn.len == 0) {
        return if (item.turn_identity != 0) item.turn_identity else item.identity;
    }

    var hash = std.hash.Wyhash.init(0x776f726b7475726e);
    hash.update(snapshot.threadId());
    hash.update(&.{0});
    hash.update(turn);
    return hash.final() | 1;
}

/// Resolves actions against the same owned page that supplied their geometry.
/// Example: `const source = window.findItem(identity) orelse return;`
pub fn findItem(self: *const Window, identity: u64) ?*const core.AgentThreadSnapshot {
    var index: usize = self.count;
    while (index > 0) {
        index -= 1;
        const snapshot = &self.pages[index].snapshot;
        if (snapshot.findItem(identity) != null) {
            return snapshot;
        }
    }

    return null;
}

/// A source fragment has one seam identity across live and historical numbering.
/// Example: `const key = Window.itemKey(snapshot, item);`
pub fn itemKey(snapshot: *const core.AgentThreadSnapshot, item: *const core.AgentThreadItem) u64 {
    const source = item.sourceId(snapshot);
    if (source.len == 0) {
        return item.identity;
    }

    var hash = std.hash.Wyhash.init(0x746872656164);
    hash.update(std.mem.asBytes(&item.source_turn_len));
    hash.update(item.sourceTurn(snapshot));
    hash.update(std.mem.asBytes(&item.source_len));
    hash.update(source);
    hash.update(std.mem.asBytes(&item.fragment_offset));
    return hash.final() | 1;
}

/// Seam admission compares complete source identities, never sampled hashes.
/// Example: `if (Window.sameFragment(left, right)) omitOlderCopy();`
pub fn sameFragment(left: Item, right: Item) bool {
    const a = left.item.sourceId(left.snapshot);
    const b = right.item.sourceId(right.snapshot);
    return a.len > 0 and left.item.fragment_offset == right.item.fragment_offset and std.mem.eql(u8, a, b) and std.mem.eql(u8, left.item.sourceTurn(left.snapshot), right.item.sourceTurn(right.snapshot));
}

const Item = @import("AgentHistoryItem.zig");

/// Keeps the runtime's failure reason without retaining its receive buffer.
/// Example: `window.fail("History is unavailable");`
pub fn fail(self: *Window, message: []const u8) void {
    self.pending = null;
    self.failed = true;
    var len = @min(message.len, self.failure_text.len);
    while (len > 0 and len < message.len and message[len] & 0xc0 == 0x80) {
        len -= 1;
    }
    @memcpy(self.failure_text[0..len], message[0..len]);
    self.failure_len = @intCast(len);
}

/// Example: `drawError(window.failureMessage());`
pub fn failureMessage(self: *const Window) []const u8 {
    return self.failure_text[0..self.failure_len];
}
