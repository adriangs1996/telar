//! Titles read back from the session checkpoint, waiting for the agent that
//! resumes each pane's session to be observed.
//!
//! A restored pane is a fresh shell; its agent aggregate only exists once the
//! runtime observes the resumed process. The title has to outlive that gap
//! without being an aggregate of its own, so it waits here keyed by the exact
//! pane generation and is consumed by the first aggregate created for it.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../pane/root.zig");
const types = @import("types.zig");

const schema = core.schema;
const PaneKey = pane_mod.PaneKey;
const SessionTitle = types.SessionTitle;

pub const RestoredTitles = struct {
    const Entry = struct {
        key: PaneKey,
        title: SessionTitle,
    };

    slots: [types.max_records]?Entry = .{null} ** types.max_records,

    /// Stores one title for a pane generation, replacing an earlier one for the
    /// same generation. Returns `false` when every slot is taken.
    ///
    /// ```zig
    /// _ = titles.put(pane.key(), title);
    /// ```
    pub fn put(titles: *RestoredTitles, key: PaneKey, title: SessionTitle) bool {
        if (titles.indexOf(key)) |index| {
            titles.slots[index].?.title = title;
            return true;
        }

        for (&titles.slots) |*slot| {
            if (slot.* != null) {
                continue;
            }

            slot.* = .{ .key = key, .title = title };
            return true;
        }

        return false;
    }

    /// Removes and returns the title waiting for one pane generation.
    ///
    /// ```zig
    /// if (titles.take(identity.key)) |title| agent.restoreTitle(title);
    /// ```
    pub fn take(titles: *RestoredTitles, key: PaneKey) ?SessionTitle {
        const index = titles.indexOf(key) orelse return null;
        const title = titles.slots[index].?.title;
        titles.slots[index] = null;
        return title;
    }

    fn indexOf(titles: *const RestoredTitles, key: PaneKey) ?usize {
        for (titles.slots, 0..) |slot, index| {
            const entry = slot orelse continue;

            if (entry.key.id == key.id and entry.key.generation == key.generation) {
                return index;
            }
        }

        return null;
    }
};

test "restored titles wait for their exact pane generation and are consumed once" {
    var titles: RestoredTitles = .{};
    const key: PaneKey = .{ .id = try schema.id.pane(4), .generation = 2 };
    const first = try SessionTitle.init("Fix the proxy", .generated);
    const second = try SessionTitle.init("Fix the proxy again", .manual);

    try std.testing.expect(titles.put(key, first));
    try std.testing.expect(titles.put(key, second));
    try std.testing.expect(titles.take(.{ .id = key.id, .generation = 3 }) == null);
    const taken = titles.take(key).?;
    try std.testing.expectEqualStrings("Fix the proxy again", taken.slice());
    try std.testing.expectEqual(schema.AgentTitleSource.manual, taken.source);
    try std.testing.expect(titles.take(key) == null);
}

test "restored titles refuse to grow past the agent record bound" {
    var titles: RestoredTitles = .{};
    const title = try SessionTitle.init("Bounded", .generated);
    var index: u32 = 1;

    while (index <= types.max_records) : (index += 1) {
        try std.testing.expect(titles.put(.{ .id = try schema.id.pane(index), .generation = 1 }, title));
    }

    try std.testing.expect(!titles.put(.{ .id = try schema.id.pane(index), .generation = 1 }, title));
}

test "session titles accept only durable sources and printable text" {
    try std.testing.expectError(error.InvalidSessionTitle, SessionTitle.init("New Claude Code session", .telar));
    try std.testing.expectError(error.InvalidSessionTitle, SessionTitle.init("window", .terminal));
    try std.testing.expectError(error.InvalidSessionTitle, SessionTitle.init("", .generated));
    try std.testing.expectError(error.InvalidSessionTitle, SessionTitle.init("a\x1bb", .generated));
    try std.testing.expectError(error.InvalidSessionTitle, SessionTitle.init("x" ** (schema.max_agent_session_title_bytes + 1), .manual));
    const title = try SessionTitle.init("Review proxy lifecycle", .generated);
    try std.testing.expectEqualStrings("Review proxy lifecycle", title.slice());
}
