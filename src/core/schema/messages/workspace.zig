//! Workspace identity, snapshots and the workspace list.

const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const launch_mod = @import("launch.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const RequestId = id.RequestId;
const WorkspaceId = id.WorkspaceId;
const TerminalSize = types.TerminalSize;
const WorkspaceLocation = types.WorkspaceLocation;
const Launch = types.Launch;
const TabDescriptor = types.TabDescriptor;
const LaunchView = launch_mod.LaunchView;
const encodeDerived = codec.encodeDerived;
const validateRequestId = codec.validateRequestId;
const validateBytes = codec.validateBytes;
const validateTabLabel = codec.validateTabLabel;
const encodeSize = codec.encodeSize;
const decodeSize = codec.decodeSize;
const encodeWorkspaceLocation = codec.encodeWorkspaceLocation;
const decodeWorkspaceLocation = codec.decodeWorkspaceLocation;

/// Forces a named workspace identity at `launch.cwd`. Unlike `open_pane`, this
/// never attaches to an existing workspace with the same path. The name is
/// explicit and remains independent from pane cwd changes.
pub const CreateWorkspace = struct {
    request_id: RequestId,
    size: TerminalSize,
    name: []const u8,
    launch: Launch,
};

pub const CreateWorkspaceView = struct {
    request_id: RequestId,
    size: TerminalSize,
    name: []const u8,
    launch: LaunchView,
};

pub const RenameWorkspace = struct {
    request_id: RequestId,
    workspace: WorkspaceLocation,
    name: []const u8,
};

pub const RequestWorkspaceSnapshot = struct {
    request_id: RequestId,
    workspace: WorkspaceLocation,
};

pub const WorkspaceSnapshot = struct {
    request_id: RequestId,
    workspace: WorkspaceLocation,
    name: []const u8,
    tabs: []const TabDescriptor,
};

pub const WorkspaceSnapshotView = struct {
    request_id: RequestId,
    workspace: WorkspaceLocation,
    name: []const u8,
    tab_count: u16,
    encoded_tabs: []const u8,

    pub fn tabs(snapshot: WorkspaceSnapshotView) TabDescriptorIterator {
        return .{
            .decoder = .init(snapshot.encoded_tabs),
            .remaining = snapshot.tab_count,
        };
    }
};

pub const TabDescriptorIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *TabDescriptorIterator) !?TabDescriptor {
        if (iterator.remaining == 0) {
            return null;
        }
        iterator.remaining -= 1;
        return .{
            .tab_id = try id.tab(try iterator.decoder.readInt(u64)),
            .position = try iterator.decoder.readInt(u16),
            .pane_count = try iterator.decoder.readInt(u16),
            .label = try iterator.decoder.readSized16(),
        };
    }
};

pub const ResyncRequired = struct {
    workspace: WorkspaceLocation,
    workspace_closed: bool,
    previous_workspace: ?WorkspaceId = null,

    pub fn validateWire(message: ResyncRequired) !void {
        try validateWorkspaceClosure(
            message.workspace,
            message.workspace_closed,
            message.previous_workspace,
        );
    }
};

pub const WorkspaceListEntry = struct {
    workspace: WorkspaceId,
    name: []const u8,
    path: []const u8,
    tab_count: u16,
    /// Current git branch (or short commit), empty when the workspace is not
    /// a repository or has not been probed yet.
    branch: []const u8 = "",
    dirty: bool = false,
};

pub const WorkspaceList = struct {
    revision: u64,
    entries: []const WorkspaceListEntry,
};

pub const WorkspaceListView = struct {
    revision: u64,
    entry_count: u16,
    encoded_entries: []const u8,

    pub fn entries(list: WorkspaceListView) WorkspaceListIterator {
        return .{
            .decoder = .init(list.encoded_entries),
            .remaining = list.entry_count,
        };
    }
};

pub const WorkspaceListIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *WorkspaceListIterator) !?WorkspaceListEntry {
        if (iterator.remaining == 0) {
            return null;
        }
        iterator.remaining -= 1;
        return try decodeWorkspaceListEntry(&iterator.decoder);
    }
};

/// A close that removed a workspace names the surviving predecessor; any
/// other close must not.
pub fn validateWorkspaceClosure(workspace: WorkspaceLocation, workspace_closed: bool, previous_workspace: ?WorkspaceId) !void {
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
    try validateRequestId(message.request_id);
    try message.size.validate();
    try validateTabLabel(message.name, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.create_workspace));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeSize(&encoder, message.size);
    try encoder.writeSized16(message.name);
    try launch_mod.encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn decodeCreateWorkspace(decoder: *wire.Decoder) !CreateWorkspaceView {
    const request_id = try id.request(try decoder.readInt(u64));
    const size = try decodeSize(decoder);
    const name = try decoder.readSized16();
    try validateTabLabel(name, false);
    return .{
        .request_id = request_id,
        .size = size,
        .name = name,
        .launch = try launch_mod.decodeLaunch(decoder),
    };
}

pub fn encodeRenameWorkspace(buffer: []u8, message: RenameWorkspace) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateTabLabel(message.name, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.rename_workspace));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeWorkspaceLocation(&encoder, message.workspace);
    try encoder.writeSized16(message.name);
    return encoder.finish();
}

pub fn decodeRenameWorkspace(decoder: *wire.Decoder) !RenameWorkspace {
    const request_id = try id.request(try decoder.readInt(u64));
    const workspace = try decodeWorkspaceLocation(decoder);
    const name = try decoder.readSized16();
    try validateTabLabel(name, false);
    return .{ .request_id = request_id, .workspace = workspace, .name = name };
}

pub fn encodeRequestWorkspaceSnapshot(buffer: []u8, message: RequestWorkspaceSnapshot) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.request_workspace_snapshot),
        buffer,
        message,
    );
}

pub fn encodeWorkspaceSnapshot(buffer: []u8, message: WorkspaceSnapshot) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.name, types.max_workspace_name_bytes, false);
    if (message.tabs.len > types.max_tabs_per_workspace) {
        return error.TooManyTabs;
    }
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.workspace_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeWorkspaceLocation(&encoder, message.workspace);
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
        try validateTabLabel(tab.label, false);
        try encoder.writeInt(u64, id.raw(tab.tab_id));
        try encoder.writeInt(u16, tab.position);
        try encoder.writeInt(u16, tab.pane_count);
        try encoder.writeSized16(tab.label);
    }
    return encoder.finish();
}

pub fn decodeWorkspaceSnapshot(decoder: *wire.Decoder) !WorkspaceSnapshotView {
    const request_id = try id.request(try decoder.readInt(u64));
    const workspace = try decodeWorkspaceLocation(decoder);
    const name = try decoder.readSized16();
    try validateBytes(name, types.max_workspace_name_bytes, false);
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
        try validateTabLabel(label, false);
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
    return encodeDerived(
        @intFromEnum(ServerTag.resync_required),
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
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.workspace_list));
    try encoder.writeInt(u64, message.revision);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries, 0..) |entry, index| {
        if (entry.workspace == .invalid) {
            return error.InvalidWorkspaceId;
        }
        try validateBytes(entry.name, types.max_workspace_name_bytes, false);
        try validateBytes(entry.path, types.max_cwd_bytes, false);
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
        try validateBytes(entry.branch, types.max_git_branch_bytes, true);
        try encoder.writeSized16(entry.branch);
        try encoder.writeByte(@intFromBool(entry.dirty));
    }
    return encoder.finish();
}

pub fn decodeWorkspaceList(decoder: *wire.Decoder) !WorkspaceListView {
    const revision = try decoder.readInt(u64);
    if (revision == 0) {
        return error.InvalidWorkspaceListRevision;
    }
    const entry_count = try decoder.readInt(u16);
    if (entry_count > types.max_workspace_list_entries) {
        return error.TooManyWorkspaces;
    }
    const entries_start = decoder.index;
    var seen: [types.max_workspace_list_entries]WorkspaceId = undefined;
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

fn decodeWorkspaceListEntry(decoder: *wire.Decoder) !WorkspaceListEntry {
    const workspace = try id.workspace(try decoder.readInt(u64));
    const name = try decoder.readSized16();
    try validateBytes(name, types.max_workspace_name_bytes, false);
    const path = try decoder.readSized16();
    try validateBytes(path, types.max_cwd_bytes, false);
    const tab_count = try decoder.readInt(u16);
    if (tab_count > types.max_tabs_per_workspace) {
        return error.TooManyTabs;
    }
    const branch = try decoder.readSized16();
    try validateBytes(branch, types.max_git_branch_bytes, true);
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
