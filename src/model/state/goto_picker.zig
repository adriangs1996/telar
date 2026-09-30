//! Pure fuzzy matching over the client's committed workspace, tab and agent
//! projections for the goto picker. Deterministic for one (sources, query)
//! pair, so the renderer and the submit path always agree on ordering.

const core = @import("telar-core");
const data = @import("../model.zig");
const Sources = @import("Sources.zig");
const tab_label = @import("../workspace/tab_label.zig");
const Results = @import("Results.zig");
const Scorer = @import("Scorer.zig");
const std = @import("std");
const AgentSnapshot = @import("../agents/AgentSnapshot.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const Tabs = @import("../workspace/Tabs.zig");

/// Every candidate the sources can hold, so an empty query lists them all.
pub const max_results = core.max_workspace_list_entries + Tabs.capacity + core.max_agent_snapshot_entries;
pub const max_label_bytes = 160;

comptime {
    // `Results.len` counts in one byte.
    std.debug.assert(max_results <= std.math.maxInt(u8));
}

pub const Item = union(enum) {
    workspace: core.WorkspaceId,
    tab: core.TabId,
    agent: data.AgentKey,
};

/// Fills `results` with every candidate matching `query`, best score first.
/// An empty query lists everything in canonical order: workspaces, then the
/// active workspace's tabs, then agents.
///
/// ```zig
/// var results: Results = .{};
/// collect(sources, prompt.field.text(), &results);
/// ```
pub fn collect(sources: Sources, query: []const u8, results: *Results) void {
    results.len = 0;
    var scorer: Scorer = .{ .sources = sources, .query = query };

    for (0..sources.workspaces.count) |index| {
        const item: Item = .{ .workspace = sources.workspaces.workspaceAt(index) };
        insert(results, item, scorer.scoreItem(item) orelse continue);
    }

    if (sources.model) |model| {
        for (model.tabs.location[0..model.tabs.count]) |location| {
            const item: Item = .{ .tab = location.tab_id };
            insert(results, item, scorer.scoreItem(item) orelse continue);
        }
    }

    for (sources.agents.slice()) |*agent| {
        const item: Item = .{ .agent = agent.key };
        insert(results, item, scorer.scoreItem(item) orelse continue);
    }
}

/// Writes the searchable one-line label for one item into `buffer`; a
/// label longer than the buffer ends at the last whole character.
///
/// ```zig
/// var buffer: [max_label_bytes]u8 = undefined;
/// const text = describe(sources, results.slice()[0].item, &buffer);
/// ```
pub fn describe(sources: Sources, item: Item, buffer: *[max_label_bytes]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    switch (item) {
        .workspace => |workspace| {
            const index = sources.workspaces.indexOf(workspace) orelse return "";
            writer.writeAll(sources.workspaces.nameAt(index)) catch {};
            const branch = sources.workspaces.branchAt(index);
            if (branch.len != 0) {
                writer.print("  {s}", .{branch}) catch {};
            }
        },
        .tab => |tab_id| {
            const model = sources.model orelse return "";
            const slot = model.tabs.find(tab_id) orelse return "";
            writer.print("tab {s}", .{tab_label.text(model, slot)}) catch {};
        },
        .agent => |key| {
            const agent = sources.agents.find(key) orelse return "";
            writer.writeAll(agent.providerName()) catch {};
            const title = agent.sessionTitle();
            if (title.len != 0) {
                writer.print("  {s}", .{title}) catch {};
            }
            const workspace_label = agent.workspaceLabel();
            if (workspace_label.len != 0) {
                writer.print("  {s}", .{workspace_label}) catch {};
            }
        },
    }

    // A full buffer takes what fits of the last write, which may end
    // inside a character; the trailing continuation bytes go.
    const written = writer.buffered();
    if (written.len < buffer.len) {
        return written;
    }

    return written[0..lastBoundary(written)];
}

/// The offset where the last character of `text` starts, or its length
/// when that character is whole.
fn lastBoundary(text: []const u8) usize {
    var start = text.len;
    while (start > 0 and text[start - 1] & continuation_mask == continuation_bits) {
        start -= 1;
    }

    if (start == 0) {
        return text.len;
    }

    const lead = text[start - 1];
    const width = std.unicode.utf8ByteSequenceLength(lead) catch return start - 1;
    return if (text.len - (start - 1) >= width) text.len else start - 1;
}

const continuation_mask: u8 = 0b1100_0000;
const continuation_bits: u8 = 0b1000_0000;

fn insert(results: *Results, item: Item, item_score: u32) void {
    var index: usize = results.len;
    while (index > 0 and results.matches[index - 1].score < item_score) {
        index -= 1;
    }

    if (index == max_results) {
        return;
    }
    const tail_end = @min(results.len, max_results - 1);
    var move: usize = tail_end;
    while (move > index) : (move -= 1) {
        results.matches[move] = results.matches[move - 1];
    }

    results.matches[index] = .{ .item = item, .score = item_score };
    if (results.len != max_results) {
        results.len += 1;
    }
}

test "collect keeps matches ordered by score with a stable bound" {
    var results: Results = .{};
    var snapshot: AgentSnapshot = .{};
    var workspaces: WorkspaceListSnapshot = .{};
    const sources: Sources = .{
        .agents = &snapshot,
        .workspaces = &workspaces,
        .model = null,
    };

    collect(sources, "", &results);
    try std.testing.expectEqual(@as(u8, 0), results.len);

    for (0..max_results + 8) |index| {
        insert(&results, .{ .workspace = @enumFromInt(index + 1) }, @intCast(index));
    }
    try std.testing.expectEqual(@as(u8, max_results), results.len);
    try std.testing.expectEqual(@as(u32, max_results + 7), results.slice()[0].score);
}

test "a label cut by its buffer ends at the last whole character" {
    try std.testing.expectEqual(@as(usize, 3), lastBoundary("abc"));
    try std.testing.expectEqual(@as(usize, 2), lastBoundary("ab\xc3\xa9"[0..3]));
    try std.testing.expectEqual(@as(usize, 4), lastBoundary("ab\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), lastBoundary("a\xe2\x82"));
}
