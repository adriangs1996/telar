//! Where each agent records its session, and how far the runtime has read
//! it. Claude Code's `/rename` fires no hook and Codex's has none either: the
//! name only lands in the file the agent's hooks point at. The runtime polls
//! that file on the observation path; this file owns the bounded watch store,
//! never the I/O or the file formats.

const Registration = @import("Registration.zig");
const Watch = @import("Watch.zig");
const Watches = @import("Watches.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const pane_module = @import("telar-core").pane;
const SessionReference = @import("SessionReference.zig");
const std = @import("std");
const AgentSessionFileKindType = @import("telar-core").AgentSessionFileKind;

pub fn fresh(registration: Registration) Watch {
    var watch: Watch = .{ .key = registration.key, .session = registration.session, .kind = registration.kind };
    @memcpy(watch.path[0..registration.path.len], registration.path);
    watch.path_len = @intCast(registration.path.len);
    return watch;
}

test "watches replace a changed path, keep progress for the same one and pick the stalest due" {
    var watches: Watches = .{};
    const key: PaneKey = .{ .id = try pane_module(7), .generation = 3 };
    const other: PaneKey = .{ .id = try pane_module(8), .generation = 1 };
    const session = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1);

    try std.testing.expect(watches.put(.{ .key = key, .session = session, .kind = .claude_transcript, .path = "/a.jsonl" }));
    watches.find(key).?.offset = 40;
    watches.find(key).?.checked_at_ms = 500;
    try std.testing.expect(watches.put(.{ .key = key, .session = session, .kind = .claude_transcript, .path = "/a.jsonl" }));
    try std.testing.expectEqual(@as(?u64, 40), watches.find(key).?.offset);
    try std.testing.expect(watches.put(.{ .key = key, .session = session, .kind = .codex_state, .path = "/a.jsonl" }));
    try std.testing.expect(watches.find(key).?.offset == null);
    try std.testing.expectEqual(AgentSessionFileKindType.codex_state, watches.find(key).?.kind);
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
        .key = .{ .id = try pane_module(7), .generation = 3 },
        .session = try SessionReference.init("abc", 1),
        .kind = .codex_state,
    };

    try std.testing.expect(watch.remember(""));
    try std.testing.expect(!watch.remember(""));
    try std.testing.expect(watch.remember("Fix proxy"));
    try std.testing.expect(!watch.remember("Fix proxy"));
    try std.testing.expect(watch.remember(""));
}
