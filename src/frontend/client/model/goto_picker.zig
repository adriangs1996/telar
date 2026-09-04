//! Pure fuzzy matching over the client's committed workspace, tab and agent
//! projections for the goto picker. Deterministic for one (sources, query)
//! pair, so the renderer and the submit path always agree on ordering.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const workspace_capability = @import("../../workspace/root.zig");

const schema = core.schema;
const workspace_list = workspace_capability.workspace_list;
const tabs_mod = workspace_capability.tabs;

pub const max_results = 64;
pub const max_label_bytes = 160;

pub const Item = union(enum) {
    workspace: schema.WorkspaceId,
    tab: schema.TabId,
    agent: agents.AgentKey,
};

pub const Match = struct {
    item: Item,
    score: u32,
};

pub const Results = struct {
    matches: [max_results]Match = undefined,
    len: u8 = 0,

    pub fn slice(results: *const Results) []const Match {
        return results.matches[0..results.len];
    }
};

pub const Sources = struct {
    agents: *const agents.Snapshot,
    workspaces: *const workspace_list.Snapshot,
    tabs: ?*const tabs_mod.Model,
};

const Scorer = struct {
    sources: Sources,
    query: []const u8,
    label: [max_label_bytes]u8 = undefined,

    fn scoreItem(scorer: *Scorer, item: Item) ?u32 {
        return score(describe(scorer.sources, item, &scorer.label), scorer.query);
    }
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

/// Shared subsequence scorer; see `telar-core`'s `fuzzy.score`.
pub const score = core.fuzzy.score;

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
    var snapshot: agents.Snapshot = .{};
    var workspaces: workspace_list.Snapshot = .{};
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
