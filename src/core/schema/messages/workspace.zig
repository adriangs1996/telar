//! Workspace identity, snapshots and the workspace list.

const types = @import("../types.zig");
const id = @import("../id.zig");
const CreateWorkspace = @import("CreateWorkspace.zig");
const codec = @import("../codec.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const launch_mod = @import("launch.zig");
const DecoderType = @import("../Decoder.zig");
const CreateWorkspaceView = @import("CreateWorkspaceView.zig");
const RenameWorkspace = @import("RenameWorkspace.zig");
const RequestWorkspaceSnapshot = @import("RequestWorkspaceSnapshot.zig");
const WorkspaceSnapshot = @import("WorkspaceSnapshot.zig");
const WorkspaceSnapshotView = @import("WorkspaceSnapshotView.zig");
const ResyncRequired = @import("ResyncRequired.zig");
const WorkspaceList = @import("WorkspaceList.zig");
const WorkspaceListView = @import("WorkspaceListView.zig");
const WorkspaceListEntry = @import("WorkspaceListEntry.zig");

/// A close that removed a workspace names the surviving predecessor; any
/// other close must not.
pub fn validateWorkspaceClosure(workspace: types.WorkspaceLocation, workspace_closed: bool, previous_workspace: ?id.WorkspaceId) !void {
    if (!workspace_closed and previous_workspace != null) {
        return error.UnexpectedPreviousWorkspace;
    }
    if (previous_workspace) |previous| {
        const closed = switch (workspace) {
            .workspace => |workspace_id| workspace_id,
            .worktree => return error.InvalidWorkspaceSuccessor,
        };
        if (previous == closed) {
            return error.InvalidWorkspaceSuccessor;
        }
    }
}

pub fn encodeCreateWorkspace(buffer: []u8, message: CreateWorkspace) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try message.size.validate();
    try codec.validateTabLabel(message.name, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.create_workspace));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeSize(&encoder, message.size);
    try encoder.writeSized16(message.name);
    try launch_mod.encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn decodeCreateWorkspace(decoder: *DecoderType) !CreateWorkspaceView {
    const request_id = try id.request(try decoder.readInt(u64));
    const size = try codec.decodeSize(decoder);
    const name = try decoder.readSized16();
    try codec.validateTabLabel(name, false);
    return .{
        .request_id = request_id,
        .size = size,
        .name = name,
        .launch = try launch_mod.decodeLaunch(decoder),
    };
}

pub fn encodeRenameWorkspace(buffer: []u8, message: RenameWorkspace) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateTabLabel(message.name, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.rename_workspace));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeWorkspaceLocation(&encoder, message.workspace);
    try encoder.writeSized16(message.name);
    return encoder.finish();
}

pub fn decodeRenameWorkspace(decoder: *DecoderType) !RenameWorkspace {
    const request_id = try id.request(try decoder.readInt(u64));
    const workspace = try codec.decodeWorkspaceLocation(decoder);
    const name = try decoder.readSized16();
    try codec.validateTabLabel(name, false);
    return .{ .request_id = request_id, .workspace = workspace, .name = name };
}

pub fn encodeRequestWorkspaceSnapshot(buffer: []u8, message: RequestWorkspaceSnapshot) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ClientTag.request_workspace_snapshot),
        buffer,
        message,
    );
}

pub fn encodeWorkspaceSnapshot(buffer: []u8, message: WorkspaceSnapshot) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateBytes(message.name, types.max_workspace_name_bytes, false);
    if (message.tabs.len > types.max_tabs_per_workspace) {
        return error.TooManyTabs;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.workspace_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeWorkspaceLocation(&encoder, message.workspace);
    try encoder.writeSized16(message.name);
    try encoder.writeInt(u16, @intCast(message.tabs.len));
    for (message.tabs, 0..) |tab, index| {
        if (tab.tab_id == .invalid) {
            return error.InvalidTabId;
        }
        if (tab.position != index) {
            return error.InvalidTabPosition;
        }
        if (tab.pane_count > types.max_panes_per_tab) {
            return error.TooManyPanes;
        }
        try codec.validateTabLabel(tab.label, false);
        try encoder.writeInt(u64, id.raw(tab.tab_id));
        try encoder.writeInt(u16, tab.position);
        try encoder.writeInt(u16, tab.pane_count);
        try encoder.writeSized16(tab.label);
    }
    return encoder.finish();
}

pub fn decodeWorkspaceSnapshot(decoder: *DecoderType) !WorkspaceSnapshotView {
    const request_id = try id.request(try decoder.readInt(u64));
    const workspace = try codec.decodeWorkspaceLocation(decoder);
    const name = try decoder.readSized16();
    try codec.validateBytes(name, types.max_workspace_name_bytes, false);
    const tab_count = try decoder.readInt(u16);
    if (tab_count > types.max_tabs_per_workspace) {
        return error.InvalidTabCount;
    }
    const tabs_start = decoder.index;
    var seen: [types.max_tabs_per_workspace]id.TabId = undefined;
    for (0..tab_count) |index| {
        const tab_id = try id.tab(try decoder.readInt(u64));
        const position = try decoder.readInt(u16);
        if (position != index) {
            return error.InvalidTabPosition;
        }
        const pane_count = try decoder.readInt(u16);
        if (pane_count > types.max_panes_per_tab) {
            return error.TooManyPanes;
        }
        const label = try decoder.readSized16();
        try codec.validateTabLabel(label, false);
        for (seen[0..index]) |previous| if (previous == tab_id) return error.DuplicateTab;
        seen[index] = tab_id;
    }
    return .{
        .request_id = request_id,
        .workspace = workspace,
        .name = name,
        .tab_count = tab_count,
        .encoded_tabs = decoder.consumed(tabs_start),
    };
}

pub fn encodeResyncRequired(buffer: []u8, message: ResyncRequired) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ServerTag.resync_required),
        buffer,
        message,
    );
}

pub fn encodeWorkspaceList(buffer: []u8, message: WorkspaceList) ![]const u8 {
    if (message.revision == 0) {
        return error.InvalidWorkspaceListRevision;
    }
    if (message.entries.len > types.max_workspace_list_entries) {
        return error.TooManyWorkspaces;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.workspace_list));
    try encoder.writeInt(u64, message.revision);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries, 0..) |entry, index| {
        if (entry.workspace == .invalid) {
            return error.InvalidWorkspaceId;
        }
        try codec.validateBytes(entry.name, types.max_workspace_name_bytes, false);
        try codec.validateBytes(entry.path, types.max_cwd_bytes, false);
        if (entry.tab_count > types.max_tabs_per_workspace) {
            return error.TooManyTabs;
        }
        for (message.entries[0..index]) |previous| {
            if (previous.workspace == entry.workspace) {
                return error.DuplicateWorkspace;
            }
        }
        try encoder.writeInt(u64, id.raw(entry.workspace));
        try encoder.writeSized16(entry.name);
        try encoder.writeSized16(entry.path);
        try encoder.writeInt(u16, entry.tab_count);
        try codec.validateBytes(entry.branch, types.max_git_branch_bytes, true);
        try encoder.writeSized16(entry.branch);
        try encoder.writeByte(@intFromBool(entry.dirty));
    }
    return encoder.finish();
}

pub fn decodeWorkspaceList(decoder: *DecoderType) !WorkspaceListView {
    const revision = try decoder.readInt(u64);
    if (revision == 0) {
        return error.InvalidWorkspaceListRevision;
    }
    const entry_count = try decoder.readInt(u16);
    if (entry_count > types.max_workspace_list_entries) {
        return error.TooManyWorkspaces;
    }
    const entries_start = decoder.index;
    var seen: [types.max_workspace_list_entries]id.WorkspaceId = undefined;
    for (0..entry_count) |index| {
        const entry = try decodeWorkspaceListEntry(decoder);
        for (seen[0..index]) |previous| {
            if (previous == entry.workspace) {
                return error.DuplicateWorkspace;
            }
        }
        seen[index] = entry.workspace;
    }
    return .{
        .revision = revision,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
}

pub fn decodeWorkspaceListEntry(decoder: *DecoderType) !WorkspaceListEntry {
    const workspace = try id.workspace(try decoder.readInt(u64));
    const name = try decoder.readSized16();
    try codec.validateBytes(name, types.max_workspace_name_bytes, false);
    const path = try decoder.readSized16();
    try codec.validateBytes(path, types.max_cwd_bytes, false);
    const tab_count = try decoder.readInt(u16);
    if (tab_count > types.max_tabs_per_workspace) {
        return error.TooManyTabs;
    }
    const branch = try decoder.readSized16();
    try codec.validateBytes(branch, types.max_git_branch_bytes, true);
    const dirty = try decoder.readBool();
    return .{
        .workspace = workspace,
        .name = name,
        .path = path,
        .tab_count = tab_count,
        .branch = branch,
        .dirty = dirty,
    };
}
