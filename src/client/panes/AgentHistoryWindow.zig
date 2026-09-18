//! Two owned pages preserve a reading window independently of live agent state.
const std = @import("std");
const core = @import("telar-core");
const Window = @This();

pub const max_scan_pages = 32;

pages: [2]core.AgentHistoryPage = undefined,
count: u8 = 0,
generation: u64 = 0,
revision: u64 = 1,
pending: ?core.agent_history.Direction = null,
direction: core.agent_history.Direction = .older,
failed: bool = false,
failure_text: [256]u8 = undefined,
failure_len: u16 = 0,
replace_seam: bool = false,
retained: bool = false,
selection_only: bool = false,
preserve_seam: bool = false,
skipped_work: ?core.agent_history.Direction = null,
scan_remaining: u8 = max_scan_pages,

/// Freezes the live seam before an asynchronous history request starts.
/// Example: `window.start(live, generation);`
pub fn start(window: *Window, live: *const core.AgentThreadSnapshot, generation: u64) void {
    window.* = .{ .generation = generation, .count = 1 };
    window.pages[0] = .{ .request_id = @enumFromInt(0), .view_generation = generation, .snapshot = live.*, .has_before = true, .has_after = false };
    for (live.items()) |item| {
        window.replace_seam = window.replace_seam or !item.fragment_end;
    }
}

/// Returns one bounded request cursor without retaining provider buffers.
/// Example: `const cursor = window.cursor(.older);`
pub fn cursor(window: *const Window, direction: core.agent_history.Direction) []const u8 {
    return if (direction == .older) window.pages[0].before.slice() else window.pages[window.count - 1].after.slice();
}

/// Example: `if (window.has(.older)) showEarlier();`
pub fn has(window: *const Window, direction: core.agent_history.Direction) bool {
    return if (direction == .older) window.pages[0].has_before else window.pages[window.count - 1].has_after;
}

/// The first retained provider item anchors a cursorless initial request.
/// Example: `request.anchor = window.anchor();`
pub fn anchor(window: *const Window) []const u8 {
    const item = window.anchorItem() orelse return "";
    return item.sourceId(&window.pages[0].snapshot);
}

/// The anchor's turn disambiguates provider item IDs reused by later turns.
/// Example: `request.anchor_turn = window.anchorTurn();`
pub fn anchorTurn(window: *const Window) []const u8 {
    const item = window.anchorItem() orelse return "";
    return item.sourceTurn(&window.pages[0].snapshot);
}

fn anchorItem(window: *const Window) ?*const core.AgentThreadItem {
    if (window.replace_seam) {
        return null;
    }
    const snapshot = &window.pages[0].snapshot;
    for (snapshot.items()) |*item| {
        if (item.sourceId(snapshot).len > 0) {
            return if (item.complete and item.sourceTurn(snapshot).len > 0) item else null;
        }
    }

    return null;
}

/// Admits only the outstanding navigation generation, keeping the shared seam.
/// Example: `_ = window.apply(page);`
pub fn apply(window: *Window, page: *const core.AgentHistoryPage) bool {
    const direction = window.pending orelse return false;
    if (page.view_generation != window.generation) {
        return false;
    }

    const more = if (direction == .older) page.has_before else page.has_after;
    const next_cursor = if (direction == .older) page.before.slice() else page.after.slice();
    if (window.preserve_seam and more and std.mem.eql(u8, window.cursor(direction), next_cursor)) {
        window.fail("History cursor did not advance");
        window.scan_remaining = 0;
        window.revision +%= 1;
        return true;
    }

    window.pending = null;
    window.failed = false;
    if (page.snapshot.item_count == 0) {
        if (direction == .older) {
            window.pages[0].has_before = page.has_before;
            window.pages[0].before = page.before;
        } else {
            window.pages[window.count - 1].has_after = page.has_after;
            window.pages[window.count - 1].after = page.after;
        }
    } else if (window.replace_seam) {
        window.pages[0] = page.*;
        window.count = 1;
        window.replace_seam = false;
    } else if (direction == .older) {
        if (!window.preserve_seam or window.count < 2) {
            window.pages[1] = window.pages[0];
            window.skipped_work = null;
        } else {
            window.skipped_work = direction;
        }
        window.pages[0] = page.*;
        window.count = 2;
    } else {
        if (!window.preserve_seam or window.count < 2) {
            window.pages[0] = window.pages[window.count - 1];
            window.skipped_work = null;
        } else {
            window.skipped_work = direction;
        }
        window.pages[1] = page.*;
        window.count = 2;
    }

    window.preserve_seam = false;
    window.revision +%= 1;
    return true;
}

/// Reopens the contiguous source window before revealing previously skipped work.
/// Example: `const direction = window.revealWork() orelse return;`
pub fn revealWork(window: *Window) ?core.agent_history.Direction {
    const direction = window.skipped_work orelse return null;
    if (direction == .older) {
        window.pages[0] = window.pages[window.count - 1];
    }

    window.count = 1;
    window.skipped_work = null;
    window.preserve_seam = false;
    window.pending = null;
    window.failed = false;
    window.scan_remaining = max_scan_pages;
    window.revision +%= 1;
    return direction;
}

/// Resolves actions against the same owned page that supplied their geometry.
/// Example: `const source = window.findItem(identity) orelse return;`
pub fn findItem(window: *const Window, identity: u64) ?*const core.AgentThreadSnapshot {
    var index: usize = window.count;
    while (index > 0) {
        index -= 1;
        const snapshot = &window.pages[index].snapshot;
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
pub fn fail(window: *Window, message: []const u8) void {
    window.pending = null;
    window.failed = true;
    var len = @min(message.len, window.failure_text.len);
    while (len > 0 and len < message.len and message[len] & 0xc0 == 0x80) {
        len -= 1;
    }
    @memcpy(window.failure_text[0..len], message[0..len]);
    window.failure_len = @intCast(len);
}

/// Example: `drawError(window.failureMessage());`
pub fn failureMessage(window: *const Window) []const u8 {
    return window.failure_text[0..window.failure_len];
}
