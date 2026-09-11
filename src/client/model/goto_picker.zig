//! Pure fuzzy matching over the client's committed workspace, tab and agent
//! projections for the goto picker. Deterministic for one (sources, query)
//! pair, so the renderer and the submit path always agree on ordering.

const WorkspaceIdType = @import("telar-core").WorkspaceId;
const TabIdType = @import("telar-core").TabId;
const AgentKeyType = @import("../agents/AgentKey.zig");
const Sources = @import("Sources.zig");
const Results = @import("Results.zig");
const Scorer = @import("Scorer.zig");
const std = @import("std");
const SnapshotType = @import("../agents/AgentSnapshot.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");

pub const max_results = 64;
pub const max_label_bytes = 160;

pub const Item = union(enum) {
    workspace: WorkspaceIdType,
    tab: TabIdType,
    agent: AgentKeyType,
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

    if (sources.tabs) |tabs| {
        for (tabs.items[0..tabs.count]) |slot| {
            const tab = &(slot orelse continue);
            const item: Item = .{ .tab = tab.location.tab_id };
            insert(results, item, scorer.scoreItem(item) orelse continue);
        }
    }

    for (sources.agents.slice()) |*agent| {
        const item: Item = .{ .agent = agent.key };
        insert(results, item, scorer.scoreItem(item) orelse continue);
    }
}

/// Writes the searchable one-line label for one item into `buffer`.
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
            const tabs = sources.tabs orelse return "";
            for (tabs.items[0..tabs.count]) |*slot| {
                const tab = if (slot.*) |*value| value else continue;
                if (tab.location.tab_id != tab_id) {
                    continue;
                }

                writer.print("tab {s}", .{tab.labelSlice()}) catch {};
                break;
            }
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

    return writer.buffered();
}

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
    var snapshot: SnapshotType = .{};
    var workspaces: WorkspaceListSnapshot = .{};
    const sources: Sources = .{
        .agents = &snapshot,
        .workspaces = &workspaces,
        .tabs = null,
    };

    collect(sources, "", &results);
    try std.testing.expectEqual(@as(u8, 0), results.len);

    for (0..max_results + 8) |index| {
        insert(&results, .{ .workspace = @enumFromInt(index + 1) }, @intCast(index));
    }
    try std.testing.expectEqual(@as(u8, max_results), results.len);
    try std.testing.expectEqual(@as(u32, max_results + 7), results.slice()[0].score);
}
