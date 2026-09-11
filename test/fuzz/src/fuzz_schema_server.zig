const decodeServer_module = @import("telar-core").decodeServer;
const ServerMessageType = @import("telar-core").ServerMessage;
const std = @import("std");
const WorkspaceSnapshotViewType = @import("telar-core").WorkspaceSnapshotView;
const TabSnapshotViewType = @import("telar-core").TabSnapshotView;
const HistoryResultsViewType = @import("telar-core").HistoryResultsView;
const AgentSnapshotViewType = @import("telar-core").AgentSnapshotView;
const WorkspaceListViewType = @import("telar-core").WorkspaceListView;

pub export fn zig_fuzz_init() callconv(.c) void {}

pub export fn zig_fuzz_test(buf: [*]const u8, len: usize) callconv(.c) void {
    const message = decodeServer_module(buf[0..len]) catch return;
    exercise(message) catch return;
}

fn exercise(message: ServerMessageType) !void {
    std.mem.doNotOptimizeAway(message);
    switch (message) {
        .workspace_snapshot => |payload| try exhaustWorkspaceSnapshot(payload),
        .tab_snapshot => |payload| try exhaustTabSnapshot(payload),
        .history_results => |payload| try exhaustHistoryResults(payload),
        .agent_snapshot => |payload| try exhaustAgentSnapshot(payload),
        .workspace_list => |payload| try exhaustWorkspaceList(payload),
        else => {},
    }
}

fn exhaustWorkspaceSnapshot(snapshot: WorkspaceSnapshotViewType) !void {
    var tabs = snapshot.tabs();
    while (try tabs.next()) |tab| {
        std.mem.doNotOptimizeAway(tab);
    }
}

fn exhaustTabSnapshot(snapshot: TabSnapshotViewType) !void {
    var panes = snapshot.panes();
    while (try panes.next()) |pane| {
        std.mem.doNotOptimizeAway(pane);
    }
}

fn exhaustHistoryResults(results: HistoryResultsViewType) !void {
    var entries = results.entries();
    while (try entries.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}

fn exhaustAgentSnapshot(snapshot: AgentSnapshotViewType) !void {
    var entries = snapshot.entries();
    while (try entries.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}

fn exhaustWorkspaceList(list: WorkspaceListViewType) !void {
    var entries = list.entries();
    while (try entries.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}
