//! Tab lifecycle inside a workspace and the per-tab pane snapshot.

const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const launch_mod = @import("launch.zig");
const workspace = @import("workspace.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const RequestId = id.RequestId;
const PaneId = id.PaneId;
const WorkspaceId = id.WorkspaceId;
const TerminalSize = types.TerminalSize;
const WorkspaceLocation = types.WorkspaceLocation;
const TabLocation = types.TabLocation;
const Launch = types.Launch;
const TabMoveDirection = types.TabMoveDirection;
const PaneDescriptor = types.PaneDescriptor;
const LaunchView = launch_mod.LaunchView;
const encodeDerived = codec.encodeDerived;
const validateRequestId = codec.validateRequestId;
const validatePaneId = codec.validatePaneId;
const validateTabLabel = codec.validateTabLabel;
const encodeSize = codec.encodeSize;
const decodeSize = codec.decodeSize;
const encodeTabLocation = codec.encodeTabLocation;
const decodeTabLocation = codec.decodeTabLocation;
const encodeWorkspaceLocation = codec.encodeWorkspaceLocation;
const decodeWorkspaceLocation = codec.decodeWorkspaceLocation;
const decodePaneLifecycle = codec.decodePaneLifecycle;

pub const RequestTabSnapshot = struct {
    request_id: RequestId,
    location: TabLocation,
};

pub const CreateTab = struct {
    request_id: RequestId,
    workspace: WorkspaceLocation,
    label: []const u8 = "",
    size: TerminalSize,
    launch: Launch,
};

pub const CreateTabView = struct {
    request_id: RequestId,
    workspace: WorkspaceLocation,
    label: []const u8,
    size: TerminalSize,
    launch: LaunchView,
};

pub const RenameTab = struct {
    request_id: RequestId,
    location: TabLocation,
    label: []const u8,
};

pub const CloseTab = struct {
    request_id: RequestId,
    location: TabLocation,
};

pub const MoveTab = struct {
    request_id: RequestId,
    location: TabLocation,
    direction: TabMoveDirection,
};

pub const TabCreated = struct {
    request_id: RequestId,
    location: TabLocation,
    position: u16,
    label: []const u8,
    root_pane_id: PaneId,
};

pub const TabRenamed = struct {
    request_id: RequestId,
    location: TabLocation,
    label: []const u8,
};

pub const TabClosed = struct {
    /// `.none` identifies a lifecycle event emitted by the runtime rather than
    /// the response to an explicit close request.
    request_id: RequestId,
    location: TabLocation,
    workspace_closed: bool,
    /// Canonical predecessor in the runtime's workspace order. Present only
    /// when this close removed the workspace and another workspace survives.
    previous_workspace: ?WorkspaceId = null,

    pub const wire_allow_zero_request_id = true;

    pub fn validateWire(message: TabClosed) !void {
        try workspace.validateWorkspaceClosure(
            message.location.workspace,
            message.workspace_closed,
            message.previous_workspace,
        );
    }
};

pub const TabMoved = struct {
    request_id: RequestId,
    location: TabLocation,
    position: u16,
};

pub const TabSnapshot = struct {
    request_id: RequestId,
    location: TabLocation,
    panes: []const PaneDescriptor,
};

pub const TabSnapshotView = struct {
    request_id: RequestId,
    location: TabLocation,
    pane_count: u16,
    encoded_panes: []const u8,

    pub fn panes(snapshot: TabSnapshotView) PaneDescriptorIterator {
        return .{
            .decoder = .init(snapshot.encoded_panes),
            .remaining = snapshot.pane_count,
        };
    }
};

pub const PaneDescriptorIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *PaneDescriptorIterator) !?PaneDescriptor {
        if (iterator.remaining == 0) {
            return null;
        }
        iterator.remaining -= 1;
        return .{
            .pane_id = try id.pane(try iterator.decoder.readInt(u64)),
            .lifecycle = try decodePaneLifecycle(try iterator.decoder.readByte()),
        };
    }
};

pub fn encodeRequestTabSnapshot(buffer: []u8, message: RequestTabSnapshot) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.request_tab_snapshot),
        RequestTabSnapshot,
        buffer,
        message,
    );
}

pub fn encodeCreateTab(buffer: []u8, message: CreateTab) ![]const u8 {
    try validateRequestId(message.request_id);
    try message.size.validate();
    try validateTabLabel(message.label, true);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.create_tab));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeWorkspaceLocation(&encoder, message.workspace);
    try encoder.writeSized16(message.label);
    try encodeSize(&encoder, message.size);
    try launch_mod.encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn decodeCreateTab(decoder: *wire.Decoder) !CreateTabView {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeWorkspaceLocation(decoder);
    const label = try decoder.readSized16();
    try validateTabLabel(label, true);
    return .{
        .request_id = request_id,
        .workspace = location,
        .label = label,
        .size = try decodeSize(decoder),
        .launch = try launch_mod.decodeLaunch(decoder),
    };
}

pub fn encodeRenameTab(buffer: []u8, message: RenameTab) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateTabLabel(message.label, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.rename_tab));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeTabLocation(&encoder, message.location);
    try encoder.writeSized16(message.label);
    return encoder.finish();
}

pub fn decodeRenameTab(decoder: *wire.Decoder) !RenameTab {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeTabLocation(decoder);
    const label = try decoder.readSized16();
    try validateTabLabel(label, false);
    return .{ .request_id = request_id, .location = location, .label = label };
}

pub fn encodeCloseTab(buffer: []u8, message: CloseTab) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.close_tab), CloseTab, buffer, message);
}

pub fn encodeMoveTab(buffer: []u8, message: MoveTab) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.move_tab), MoveTab, buffer, message);
}

pub fn encodeTabSnapshot(buffer: []u8, message: TabSnapshot) ![]const u8 {
    try validateRequestId(message.request_id);
    if (message.panes.len > types.max_panes_per_tab) {
        return error.TooManyPanes;
    }

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.tab_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeTabLocation(&encoder, message.location);
    try encoder.writeInt(u16, @intCast(message.panes.len));
    for (message.panes, 0..) |pane, pane_index| {
        try validatePaneId(pane.pane_id);
        for (message.panes[0..pane_index]) |previous| {
            if (previous.pane_id == pane.pane_id) {
                return error.DuplicatePane;
            }
        }
        try encoder.writeInt(u64, id.raw(pane.pane_id));
        try encoder.writeByte(@intFromEnum(pane.lifecycle));
    }
    return encoder.finish();
}

pub fn decodeTabSnapshot(decoder: *wire.Decoder) !TabSnapshotView {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeTabLocation(decoder);
    const pane_count = try decoder.readInt(u16);
    if (pane_count > types.max_panes_per_tab) {
        return error.TooManyPanes;
    }

    const panes_start = decoder.index;
    // Quadratic duplicate scan, acceptable while max_panes_per_tab is 64;
    // revisit before raising the limit.
    var seen: [types.max_panes_per_tab]PaneId = undefined;
    for (0..pane_count) |pane_index| {
        const pane_id = try id.pane(try decoder.readInt(u64));
        _ = try decodePaneLifecycle(try decoder.readByte());
        for (seen[0..pane_index]) |previous| {
            if (previous == pane_id) {
                return error.DuplicatePane;
            }
        }
        seen[pane_index] = pane_id;
    }
    return .{
        .request_id = request_id,
        .location = location,
        .pane_count = pane_count,
        .encoded_panes = decoder.consumed(panes_start),
    };
}

pub fn encodeTabCreated(buffer: []u8, message: TabCreated) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.root_pane_id);
    try validateTabLabel(message.label, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.tab_created));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeTabLocation(&encoder, message.location);
    try encoder.writeInt(u16, message.position);
    try encoder.writeSized16(message.label);
    try encoder.writeInt(u64, id.raw(message.root_pane_id));
    return encoder.finish();
}

pub fn decodeTabCreated(decoder: *wire.Decoder) !TabCreated {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeTabLocation(decoder);
    const position = try decoder.readInt(u16);
    const label = try decoder.readSized16();
    try validateTabLabel(label, false);
    return .{
        .request_id = request_id,
        .location = location,
        .position = position,
        .label = label,
        .root_pane_id = try id.pane(try decoder.readInt(u64)),
    };
}

pub fn encodeTabRenamed(buffer: []u8, message: TabRenamed) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateTabLabel(message.label, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.tab_renamed));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeTabLocation(&encoder, message.location);
    try encoder.writeSized16(message.label);
    return encoder.finish();
}

pub fn decodeTabRenamed(decoder: *wire.Decoder) !TabRenamed {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeTabLocation(decoder);
    const label = try decoder.readSized16();
    try validateTabLabel(label, false);
    return .{ .request_id = request_id, .location = location, .label = label };
}

pub fn encodeTabClosed(buffer: []u8, message: TabClosed) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.tab_closed), TabClosed, buffer, message);
}

pub fn encodeTabMoved(buffer: []u8, message: TabMoved) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.tab_moved), TabMoved, buffer, message);
}
