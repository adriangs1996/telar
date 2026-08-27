const std = @import("std");
const schema = @import("telar-core").schema;

pub export fn zig_fuzz_init() callconv(.c) void {}

pub export fn zig_fuzz_test(buf: [*]const u8, len: usize) callconv(.c) void {
    const message = schema.decodeServer(buf[0..len]) catch return;
    exercise(message) catch return;
}

fn exercise(message: schema.ServerMessage) !void {
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

fn exhaustWorkspaceSnapshot(snapshot: schema.WorkspaceSnapshotView) !void {
    var tabs = snapshot.tabs();
    while (try tabs.next()) |tab| {
        std.mem.doNotOptimizeAway(tab);
    }
}

fn exhaustTabSnapshot(snapshot: schema.TabSnapshotView) !void {
    var panes = snapshot.panes();
    while (try panes.next()) |pane| {
        std.mem.doNotOptimizeAway(pane);
    }
}

fn exhaustHistoryResults(results: schema.HistoryResultsView) !void {
    var entries = results.entries();
    while (try entries.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}

fn exhaustAgentSnapshot(snapshot: schema.AgentSnapshotView) !void {
    var entries = snapshot.entries();
    while (try entries.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}

fn exhaustWorkspaceList(list: schema.WorkspaceListView) !void {
    var entries = list.entries();
    while (try entries.next()) |entry| {
        std.mem.doNotOptimizeAway(entry);
    }
}
