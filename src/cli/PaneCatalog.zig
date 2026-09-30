const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const PaneRecord = @import("PaneRecord.zig");
const PaneCatalog = @This();

session: *Session,
workspace: ?core.WorkspaceId = null,
tab: ?core.TabId = null,
/// Every pane the runtime holds fits, so an unfiltered listing is whole.
entries: [core.max_panes]PaneRecord = undefined,
count: usize = 0,

/// Copies topology before the receive buffer is reused. Example: `try catalog.load();`
pub fn load(self: *PaneCatalog) !void {
    self.count = 0;
    if (self.workspace) |workspace| {
        return self.loadWorkspace(workspace);
    }

    var workspaces: [core.max_workspace_list_entries]core.WorkspaceId = undefined;
    var count: usize = 0;
    try self.session.subscribeRuntime();
    while (true) {
        const response = try self.session.receive();
        if (response != .workspace_list) {
            continue;
        }

        var entries = response.workspace_list.entries();
        while (try entries.next()) |entry| {
            if (count == workspaces.len) {
                return error.TopologyLimitReached;
            }

            workspaces[count] = entry.workspace;
            count += 1;
        }

        break;
    }

    for (workspaces[0..count]) |workspace| {
        try self.loadWorkspace(workspace);
    }
}

fn loadWorkspace(self: *PaneCatalog, workspace: core.WorkspaceId) !void {
    if (self.tab) |tab| {
        return self.loadTab(.{ .workspace = .{ .workspace = workspace }, .tab_id = tab });
    }

    const response = try self.session.exchange(core.encodeRequestWorkspaceSnapshot, core.RequestWorkspaceSnapshot{ .request_id = .none, .workspace = .{ .workspace = workspace } });
    if (response != .workspace_snapshot or response.workspace_snapshot.workspace != .workspace or response.workspace_snapshot.workspace.workspace != workspace) {
        return error.UnexpectedRuntimeResponse;
    }

    var tabs: [core.max_tabs_per_workspace]core.TabId = undefined;
    var count: usize = 0;
    var entries = response.workspace_snapshot.tabs();
    while (try entries.next()) |entry| {
        if (count == tabs.len) {
            return error.TopologyLimitReached;
        }

        tabs[count] = entry.tab_id;
        count += 1;
    }

    for (tabs[0..count]) |tab| {
        try self.loadTab(.{ .workspace = .{ .workspace = workspace }, .tab_id = tab });
    }
}

fn loadTab(self: *PaneCatalog, location: core.TabLocation) !void {
    const response = try self.session.exchange(core.encodeRequestTabSnapshot, core.RequestTabSnapshot{ .request_id = .none, .location = location });
    if (response != .tab_snapshot or !std.meta.eql(response.tab_snapshot.location, location)) {
        return error.UnexpectedRuntimeResponse;
    }

    var entries = response.tab_snapshot.panes();
    var position: u16 = 0;
    while (try entries.next()) |pane| {
        if (self.count == self.entries.len) {
            return error.TopologyLimitReached;
        }

        self.entries[self.count] = .{ .location = location, .position = position, .pane = pane };
        self.count += 1;
        position += 1;
    }
}
