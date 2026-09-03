//! Where each agent records its session, and how far the runtime has read
//! it. Claude Code's `/rename` fires no hook and Codex's has none either: the
//! name only lands in the file the agent's hooks point at. The runtime polls
//! that file on the observation path; this file owns the bounded watch store,
//! never the I/O or the file formats.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../pane/root.zig");
const types = @import("types.zig");

const schema = core.schema;
const PaneKey = pane_mod.PaneKey;
const SessionReference = types.SessionReference;

pub const max_path_bytes = schema.max_agent_session_file_bytes;
pub const Kind = schema.AgentSessionFileKind;

/// One agent's session file and the probe state that belongs to it.
pub const Watch = struct {
    key: PaneKey,
    session: SessionReference,
    kind: Kind,
    path: [max_path_bytes]u8 = undefined,
    path_len: u16 = 0,
    /// Transcript scan position. Null until the first probe seeds it at the
    /// end of the file, so only names given after the watch began are read.
    offset: ?u64 = null,
    /// The last name handed to the agent, so a state database read every
    /// second reports only changes.
    name: [schema.max_agent_session_title_bytes]u8 = undefined,
    name_len: u8 = 0,
    name_known: bool = false,
    checked_at_ms: i64 = 0,
    pending: bool = false,

    pub fn pathSlice(watch: *const Watch) []const u8 {
        return watch.path[0..watch.path_len];
    }

    pub fn nameSlice(watch: *const Watch) []const u8 {
        return watch.name[0..watch.name_len];
    }

    /// Records a name as handed over and reports whether it differs from the
    /// previous one.
    ///
    /// ```zig
    /// if (watch.remember(title)) apply(title);
    /// ```
    pub fn remember(watch: *Watch, value: []const u8) bool {
        if (watch.name_known and std.mem.eql(u8, watch.nameSlice(), value)) {
            return false;
        }

        @memcpy(watch.name[0..value.len], value);
        watch.name_len = @intCast(value.len);
        watch.name_known = true;
        return true;
    }
};

/// What one probe found: the next transcript offset and, when a name was
/// read, the current one. An empty name clears the title.
pub const Completion = struct {
    key: PaneKey,
    offset: ?u64,
    title: [schema.max_agent_session_title_bytes]u8 = undefined,
    title_len: u8 = 0,
    has_title: bool = false,

    pub fn titleSlice(completion: *const Completion) []const u8 {
        return completion.title[0..completion.title_len];
    }

    pub fn setTitle(completion: *Completion, value: []const u8) void {
        @memcpy(completion.title[0..value.len], value);
        completion.title_len = @intCast(value.len);
        completion.has_title = true;
    }
};

/// The session file one agent's hooks point at.
pub const Registration = struct {
    key: PaneKey,
    session: SessionReference,
    kind: Kind,
    path: []const u8,
};

pub const Watches = struct {
    slots: [types.max_records]?Watch = @splat(null),

    /// Registers or refreshes the session file of one pane generation. A
    /// changed path, kind or session restarts the watch; the same ones keep
    /// their progress. Returns `false` when every slot is taken or the path
    /// exceeds the bound.
    ///
    /// ```zig
    /// _ = watches.put(.{ .key = pane.key(), .session = reference, .kind = .claude_transcript, .path = path });
    /// ```
    pub fn put(watches: *Watches, registration: Registration) bool {
        const path = registration.path;
        if (path.len == 0 or path.len > max_path_bytes) {
            return false;
        }

        if (watches.find(registration.key)) |watch| {
            if (watch.kind == registration.kind and std.mem.eql(u8, watch.pathSlice(), path) and
                std.mem.eql(u8, watch.session.slice(), registration.session.slice()))
            {
                return true;
            }

            watch.* = fresh(registration);
            return true;
        }

        for (&watches.slots) |*slot| {
            if (slot.* != null) {
                continue;
            }

            slot.* = fresh(registration);
            return true;
        }

        return false;
    }

    pub fn find(watches: *Watches, key: PaneKey) ?*Watch {
        for (&watches.slots) |*slot| {
            if (slot.*) |*watch| {
                if (watch.key.id == key.id and watch.key.generation == key.generation) {
                    return watch;
                }
            }
        }

        return null;
    }

    pub fn remove(watches: *Watches, key: PaneKey) bool {
        for (&watches.slots) |*slot| {
            if (slot.*) |watch| {
                if (watch.key.id == key.id and watch.key.generation == key.generation) {
                    slot.* = null;
                    return true;
                }
            }
        }

        return false;
    }

    /// The due watch whose last probe is the oldest, or null when none is
    /// due. A pending watch is never returned twice.
    ///
    /// ```zig
    /// const watch = watches.stalest(now_ms, 1_000) orelse return;
    /// ```
    pub fn stalest(watches: *Watches, now_ms: i64, interval_ms: i64) ?*Watch {
        var chosen: ?*Watch = null;
        for (&watches.slots) |*slot| {
            const watch = if (slot.*) |*value| value else continue;
            if (watch.pending or now_ms - watch.checked_at_ms < interval_ms) {
                continue;
            }

            if (chosen == null or watch.checked_at_ms < chosen.?.checked_at_ms) {
                chosen = watch;
            }
        }

        return chosen;
    }

    pub fn count(watches: *const Watches) usize {
        var total: usize = 0;
        for (&watches.slots) |slot| {
            if (slot != null) {
                total += 1;
            }
        }

        return total;
    }
};

fn fresh(registration: Registration) Watch {
    var watch: Watch = .{ .key = registration.key, .session = registration.session, .kind = registration.kind };
    @memcpy(watch.path[0..registration.path.len], registration.path);
    watch.path_len = @intCast(registration.path.len);
    return watch;
}

test "watches replace a changed path, keep progress for the same one and pick the stalest due" {
    var watches: Watches = .{};
    const key: PaneKey = .{ .id = try schema.id.pane(7), .generation = 3 };
    const other: PaneKey = .{ .id = try schema.id.pane(8), .generation = 1 };
    const session = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1);

    try std.testing.expect(watches.put(.{ .key = key, .session = session, .kind = .claude_transcript, .path = "/a.jsonl" }));
    watches.find(key).?.offset = 40;
    watches.find(key).?.checked_at_ms = 500;
    try std.testing.expect(watches.put(.{ .key = key, .session = session, .kind = .claude_transcript, .path = "/a.jsonl" }));
    try std.testing.expectEqual(@as(?u64, 40), watches.find(key).?.offset);
    try std.testing.expect(watches.put(.{ .key = key, .session = session, .kind = .codex_state, .path = "/a.jsonl" }));
    try std.testing.expect(watches.find(key).?.offset == null);
    try std.testing.expectEqual(Kind.codex_state, watches.find(key).?.kind);
    try std.testing.expect(!watches.put(.{ .key = key, .session = session, .kind = .codex_state, .path = "" }));
    try std.testing.expectEqual(@as(usize, 1), watches.count());

    watches.find(key).?.checked_at_ms = 900;
    try std.testing.expect(watches.put(.{ .key = other, .session = session, .kind = .claude_transcript, .path = "/c.jsonl" }));
    watches.find(other).?.checked_at_ms = 100;
    try std.testing.expect(watches.stalest(1_000, 1_000) == null);
    try std.testing.expectEqual(other, watches.stalest(1_200, 1_000).?.key);
    watches.find(other).?.pending = true;
    try std.testing.expect(watches.stalest(1_200, 1_000) == null);
    try std.testing.expectEqual(key, watches.stalest(2_000, 1_000).?.key);
    try std.testing.expect(watches.remove(other));
    try std.testing.expect(!watches.remove(other));
    try std.testing.expectEqual(@as(usize, 1), watches.count());
}

test "a watch remembers the last name it handed over" {
    var watch: Watch = .{
        .key = .{ .id = try schema.id.pane(7), .generation = 3 },
        .session = try SessionReference.init("abc", 1),
        .kind = .codex_state,
    };

    try std.testing.expect(watch.remember(""));
    try std.testing.expect(!watch.remember(""));
    try std.testing.expect(watch.remember("Fix proxy"));
    try std.testing.expect(!watch.remember("Fix proxy"));
    try std.testing.expect(watch.remember(""));
}
