//! Application messages for Telar's single current protocol schema.
//!
//! The handshake selects this schema before either peer calls these decoders.
//! Every function borrows input and caller-owned output memory; none allocates.

const std = @import("std");
const wire = @import("wire.zig");
pub const graphics = @import("graphics.zig");

pub const frame = @import("frame.zig");
pub const id = @import("id.zig");
pub const WorkspaceId = id.WorkspaceId;
pub const WorktreeId = id.WorktreeId;
pub const TabId = id.TabId;
pub const PaneId = id.PaneId;
pub const RequestId = id.RequestId;

const types = @import("types.zig");
const codec = @import("codec.zig");

pub const max_input_bytes = types.max_input_bytes;
pub const max_cwd_bytes = types.max_cwd_bytes;
pub const max_workspace_name_bytes = types.max_workspace_name_bytes;
pub const max_argument_count = types.max_argument_count;
pub const max_argument_bytes = types.max_argument_bytes;
pub const max_environment_count = types.max_environment_count;
pub const max_environment_bytes = types.max_environment_bytes;
pub const max_error_message_bytes = types.max_error_message_bytes;
pub const max_tab_label_bytes = types.max_tab_label_bytes;
pub const max_tabs_per_workspace = types.max_tabs_per_workspace;
pub const max_panes_per_tab = types.max_panes_per_tab;
pub const max_history_query_bytes = types.max_history_query_bytes;
pub const max_history_results = types.max_history_results;
pub const max_history_command_bytes = types.max_history_command_bytes;
pub const max_agent_snapshot_entries = types.max_agent_snapshot_entries;
pub const max_workspace_list_entries = types.max_workspace_list_entries;

pub const TerminalSize = types.TerminalSize;
pub const PaneTarget = types.PaneTarget;
pub const WorkspaceLocation = types.WorkspaceLocation;
pub const TabLocation = types.TabLocation;
pub const EnvironmentMode = types.EnvironmentMode;
pub const EnvironmentEntry = types.EnvironmentEntry;
pub const Launch = types.Launch;
pub const TabMoveDirection = types.TabMoveDirection;
pub const ExitKind = types.ExitKind;
pub const FailureCode = types.FailureCode;
pub const PaneLifecycle = types.PaneLifecycle;
pub const PaneDescriptor = types.PaneDescriptor;
pub const TabDescriptor = types.TabDescriptor;
pub const HistoryScope = types.HistoryScope;
pub const HistoryStatus = types.HistoryStatus;
pub const HistoryEntry = types.HistoryEntry;
pub const AgentProvider = types.AgentProvider;
pub const AgentStatus = types.AgentStatus;
pub const AgentSource = types.AgentSource;
pub const AgentAuthority = types.AgentAuthority;
pub const AgentSnapshotEntry = types.AgentSnapshotEntry;

const Derived = codec.Derived;
const encodeDerived = codec.encodeDerived;
const validateRequestId = codec.validateRequestId;
const validatePaneId = codec.validatePaneId;
const validateBytes = codec.validateBytes;
const validateEnvironmentEntry = codec.validateEnvironmentEntry;
const validateErrorMessage = codec.validateErrorMessage;
const validateTabLabel = codec.validateTabLabel;
const encodeSize = codec.encodeSize;
const decodeSize = codec.decodeSize;
const encodeTabLocation = codec.encodeTabLocation;
const decodeTabLocation = codec.decodeTabLocation;
const encodeWorkspaceLocation = codec.encodeWorkspaceLocation;
const decodeWorkspaceLocation = codec.decodeWorkspaceLocation;
const decodeEnvironmentMode = codec.decodeEnvironmentMode;
const decodeExitKind = codec.decodeExitKind;
const decodePaneLifecycle = codec.decodePaneLifecycle;
const decodeHistoryScope = codec.decodeHistoryScope;
const decodeHistoryStatus = codec.decodeHistoryStatus;
const decodeFailureCode = codec.decodeFailureCode;

pub const ClientTag = enum(u8) {
    open_pane = 0x01,
    pane_input = 0x02,
    pane_resize = 0x03,
    frame_ack = 0x04,
    request_snapshot = 0x05,
    detach_pane = 0x06,
    runtime_stop = 0x07,
    request_tab_snapshot = 0x08,
    create_pane = 0x09,
    close_pane = 0x0a,
    query_history = 0x0b,
    request_workspace_snapshot = 0x0c,
    create_tab = 0x0d,
    rename_tab = 0x0e,
    close_tab = 0x0f,
    move_tab = 0x10,
    request_graphics_snapshot = 0x11,
    graphics_credit = 0x12,
    configure_graphics = 0x13,
    request_runtime_state = 0x14,
    create_workspace = 0x15,
    rename_workspace = 0x16,
};

pub const ServerTag = enum(u8) {
    pane_opened = 0x81,
    pane_frame = 0x82,
    pane_exited = 0x83,
    request_failed = 0x84,
    runtime_stopping = 0x85,
    tab_snapshot = 0x86,
    history_results = 0x87,
    workspace_snapshot = 0x88,
    tab_created = 0x89,
    tab_renamed = 0x8a,
    tab_closed = 0x8b,
    tab_moved = 0x8c,
    graphics_snapshot = 0x8d,
    graphics_image = 0x8e,
    graphics_image_chunk = 0x8f,
    graphics_placement = 0x90,
    graphics_delete_image = 0x91,
    graphics_delete_placement = 0x92,
    resync_required = 0x93,
    graphics_shared_image = 0x94,
    proxy_status = 0x95,
    agent_snapshot = 0x96,
    system_metrics = 0x97,
    workspace_list = 0x98,
    pane_cwd = 0x99,
};

pub const LaunchView = struct {
    cwd: []const u8,
    argument_count: u16,
    encoded_arguments: []const u8,
    environment_mode: EnvironmentMode,
    environment_count: u16,
    encoded_environment: []const u8,

    pub fn arguments(launch: LaunchView) ArgumentIterator {
        return .{
            .decoder = .init(launch.encoded_arguments),
            .remaining = launch.argument_count,
        };
    }

    pub fn environment(launch: LaunchView) EnvironmentIterator {
        return .{
            .decoder = .init(launch.encoded_environment),
            .remaining = launch.environment_count,
        };
    }
};

pub const ArgumentIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,
    index: u16 = 0,

    pub fn next(iterator: *ArgumentIterator) !?[]const u8 {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        defer iterator.index += 1;
        const argument = try iterator.decoder.readSized16();
        try validateBytes(argument, std.math.maxInt(u16), iterator.index != 0);
        return argument;
    }
};

pub const EnvironmentIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *EnvironmentIterator) !?EnvironmentEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        const entry: EnvironmentEntry = .{
            .name = try iterator.decoder.readSized16(),
            .value = try iterator.decoder.readSized32(),
        };
        try validateEnvironmentEntry(entry);
        return entry;
    }
};

/// Opens the default pane in the workspace implied by `launch.cwd`, creating
/// it when none exists, or attaches to a specific existing pane. This makes
/// attach-or-create atomic.
pub const OpenPane = struct {
    request_id: RequestId,
    target: PaneTarget = .default,
    size: TerminalSize,
    launch: ?Launch,
};

pub const OpenPaneView = struct {
    request_id: RequestId,
    target: PaneTarget,
    size: TerminalSize,
    launch: ?LaunchView,
};

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

pub const PaneInput = struct {
    pane_id: PaneId,
    bytes: []const u8,
};

pub const PaneResize = struct {
    pane_id: PaneId,
    size: TerminalSize,
};

pub const FrameAck = struct {
    pane_id: PaneId,
    frame_id: u64,

    pub fn validateWire(message: FrameAck) !void {
        if (message.frame_id == 0) return error.InvalidFrameId;
    }
};

pub const GraphicsCredit = struct {
    pane_id: PaneId,
    bytes: u64,

    pub fn validateWire(message: GraphicsCredit) !void {
        if (message.bytes == 0) return error.InvalidGraphicsCredit;
    }
};

/// Explicit per-session graphics capability. `shared` declares that this
/// client shares the runtime's machine and can map POSIX shared memory the
/// runtime names; the runtime never assumes it. Sent before the first pane
/// attaches, and the setting applies to attachments created afterwards.
pub const ConfigureGraphics = struct {
    shared: bool,

    pub fn validateWire(message: ConfigureGraphics) !void {
        _ = message;
    }
};

pub const RequestSnapshot = struct {
    pane_id: PaneId,
    /// Last frame applied by the client. Zero means it has no pane state.
    known_frame_id: u64,
};

pub const DetachPane = struct {
    pane_id: PaneId,
};

pub const RequestTabSnapshot = struct {
    request_id: RequestId,
    location: TabLocation,
};

pub const CreatePane = struct {
    request_id: RequestId,
    location: TabLocation,
    size: TerminalSize,
    launch: Launch,
};

pub const CreatePaneView = struct {
    request_id: RequestId,
    location: TabLocation,
    size: TerminalSize,
    launch: LaunchView,
};

pub const ClosePane = struct {
    request_id: RequestId,
    pane_id: PaneId,
};

pub const RequestWorkspaceSnapshot = struct {
    request_id: RequestId,
    workspace: WorkspaceLocation,
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

pub const RequestGraphicsSnapshot = struct { pane_id: PaneId };

pub const QueryHistory = struct {
    request_id: RequestId,
    query: []const u8 = "",
    scope: HistoryScope = .global,
    scope_value: []const u8 = "",
    pane_id: PaneId = .invalid,
    failed_only: bool = false,
    limit: u16 = 20,
};

pub const ClientMessage = union(enum) {
    open_pane: OpenPaneView,
    pane_input: PaneInput,
    pane_resize: PaneResize,
    frame_ack: FrameAck,
    request_snapshot: RequestSnapshot,
    detach_pane: DetachPane,
    runtime_stop: void,
    request_tab_snapshot: RequestTabSnapshot,
    create_pane: CreatePaneView,
    close_pane: ClosePane,
    query_history: QueryHistory,
    request_workspace_snapshot: RequestWorkspaceSnapshot,
    create_tab: CreateTabView,
    rename_tab: RenameTab,
    close_tab: CloseTab,
    move_tab: MoveTab,
    request_graphics_snapshot: RequestGraphicsSnapshot,
    graphics_credit: GraphicsCredit,
    configure_graphics: ConfigureGraphics,
    request_runtime_state: void,
    create_workspace: CreateWorkspaceView,
    rename_workspace: RenameWorkspace,
};

pub const PaneOpened = struct {
    request_id: RequestId,
    pane_id: PaneId,
    location: TabLocation,
    created: bool,
};

pub const PaneExited = struct {
    pane_id: PaneId,
    kind: ExitKind,
    value: u32,
};

pub const PaneCwd = struct {
    pane_id: PaneId,
    cwd: []const u8,
};

pub const RequestFailed = struct {
    /// Zero identifies a connection-level error rather than a request.
    request_id: RequestId,
    code: FailureCode,
    message: []const u8,
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

fn validateWorkspaceClosure(
    workspace: WorkspaceLocation,
    workspace_closed: bool,
    previous_workspace: ?WorkspaceId,
) !void {
    if (!workspace_closed and previous_workspace != null)
        return error.UnexpectedPreviousWorkspace;
    if (previous_workspace) |previous| {
        const closed = switch (workspace) {
            .workspace => |workspace_id| workspace_id,
            .worktree => return error.InvalidWorkspaceSuccessor,
        };
        if (previous == closed) return error.InvalidWorkspaceSuccessor;
    }
}

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
        try validateWorkspaceClosure(
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

pub const HistoryResults = struct {
    request_id: RequestId,
    entries: []const HistoryEntry,
};

pub const HistoryResultsView = struct {
    request_id: RequestId,
    entry_count: u16,
    encoded_entries: []const u8,

    pub fn entries(results: HistoryResultsView) HistoryEntryIterator {
        return .{
            .decoder = .init(results.encoded_entries),
            .remaining = results.entry_count,
        };
    }
};

pub const ProxyStatus = struct {
    active: bool,

    pub fn validateWire(message: ProxyStatus) !void {
        _ = message;
    }
};

/// Host health sampled by the runtime, so the client reports the machine the
/// agents actually run on rather than the one showing the UI. Memory is in
/// tenths of a GiB so neither peer formats floating point. A host without a
/// battery reports `has_battery = false` and the client hides the segment.
pub const SystemMetrics = struct {
    revision: u64,
    cpu_percent: u8,
    memory_used_decigib: u16,
    has_battery: bool,
    battery_percent: u8,

    pub fn validateWire(message: SystemMetrics) !void {
        if (message.revision == 0) return error.InvalidMetricsRevision;
        if (message.cpu_percent > 100) return error.InvalidMetricsValue;
        if (message.has_battery and message.battery_percent > 100)
            return error.InvalidMetricsValue;
        if (!message.has_battery and message.battery_percent != 0)
            return error.InvalidMetricsValue;
    }
};

pub const WorkspaceListEntry = struct {
    workspace: WorkspaceId,
    name: []const u8,
    path: []const u8,
    tab_count: u16,
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
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return try decodeWorkspaceListEntry(&iterator.decoder);
    }
};

pub const AgentSnapshot = struct {
    revision: u64,
    entries: []const AgentSnapshotEntry,
};

pub const AgentSnapshotView = struct {
    revision: u64,
    entry_count: u16,
    encoded_entries: []const u8,

    pub fn entries(snapshot: AgentSnapshotView) AgentSnapshotIterator {
        return .{
            .decoder = .init(snapshot.encoded_entries),
            .remaining = snapshot.entry_count,
        };
    }
};

pub const HistoryEntryIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *HistoryEntryIterator) !?HistoryEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return try decodeHistoryEntry(&iterator.decoder);
    }
};

pub const AgentSnapshotIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *AgentSnapshotIterator) !?AgentSnapshotEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return try decodeAgentSnapshotEntry(&iterator.decoder);
    }
};

pub const PaneDescriptorIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *PaneDescriptorIterator) !?PaneDescriptor {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return .{
            .pane_id = try id.pane(try iterator.decoder.readInt(u64)),
            .lifecycle = try decodePaneLifecycle(try iterator.decoder.readByte()),
        };
    }
};

pub const TabDescriptorIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *TabDescriptorIterator) !?TabDescriptor {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return .{
            .tab_id = try id.tab(try iterator.decoder.readInt(u64)),
            .position = try iterator.decoder.readInt(u16),
            .pane_count = try iterator.decoder.readInt(u16),
            .label = try iterator.decoder.readSized16(),
        };
    }
};

pub const ServerMessage = union(enum) {
    pane_opened: PaneOpened,
    pane_frame: frame.FrameView,
    pane_exited: PaneExited,
    request_failed: RequestFailed,
    runtime_stopping: void,
    tab_snapshot: TabSnapshotView,
    history_results: HistoryResultsView,
    workspace_snapshot: WorkspaceSnapshotView,
    tab_created: TabCreated,
    tab_renamed: TabRenamed,
    tab_closed: TabClosed,
    tab_moved: TabMoved,
    graphics_snapshot: graphics.Snapshot,
    graphics_image: graphics.Image,
    graphics_image_chunk: graphics.ImageChunk,
    graphics_placement: graphics.Placement,
    graphics_delete_image: graphics.DeleteImage,
    graphics_delete_placement: graphics.DeletePlacement,
    resync_required: ResyncRequired,
    graphics_shared_image: graphics.SharedImage,
    proxy_status: ProxyStatus,
    agent_snapshot: AgentSnapshotView,
    system_metrics: SystemMetrics,
    workspace_list: WorkspaceListView,
    pane_cwd: PaneCwd,
};

pub fn encodeOpenPane(buffer: []u8, message: OpenPane) ![]const u8 {
    try validateRequestId(message.request_id);
    try message.size.validate();

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.open_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    var default_launch: ?Launch = null;
    switch (message.target) {
        .default => {
            try encoder.writeByte(0);
            default_launch = message.launch orelse return error.MissingLaunch;
        },
        .pane => |pane_id| {
            try validatePaneId(pane_id);
            if (message.launch != null) return error.UnexpectedLaunch;
            try encoder.writeByte(1);
            try encoder.writeInt(u64, id.raw(pane_id));
        },
        .workspace => |workspace_id| {
            if (workspace_id == .invalid) return error.InvalidWorkspaceId;
            if (message.launch != null) return error.UnexpectedLaunch;
            try encoder.writeByte(2);
            try encoder.writeInt(u64, id.raw(workspace_id));
        },
    }
    try encodeSize(&encoder, message.size);
    if (default_launch) |launch| try encodeLaunch(&encoder, launch);
    return encoder.finish();
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
    try encodeLaunch(&encoder, message.launch);
    return encoder.finish();
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

pub fn encodePaneInput(buffer: []u8, message: PaneInput) ![]const u8 {
    try validatePaneId(message.pane_id);
    if (message.bytes.len == 0 or message.bytes.len > max_input_bytes)
        return error.InvalidInputLength;

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.pane_input));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeBytes(message.bytes);
    return encoder.finish();
}

pub fn encodePaneResize(buffer: []u8, message: PaneResize) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.pane_resize), PaneResize, buffer, message);
}

pub fn encodeFrameAck(buffer: []u8, message: FrameAck) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.frame_ack), FrameAck, buffer, message);
}

pub fn encodeGraphicsCredit(buffer: []u8, message: GraphicsCredit) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.graphics_credit), GraphicsCredit, buffer, message);
}

pub fn encodeConfigureGraphics(buffer: []u8, message: ConfigureGraphics) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.configure_graphics), ConfigureGraphics, buffer, message);
}

/// Subscribes this client session to runtime-owned UI state, including the
/// ProxyTLS status and agent activity snapshots. The subscription lasts until
/// the client disconnects.
pub fn encodeRequestRuntimeState(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.request_runtime_state));
    return encoder.finish();
}

pub fn encodeRequestSnapshot(buffer: []u8, message: RequestSnapshot) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.request_snapshot), RequestSnapshot, buffer, message);
}

pub fn encodeDetachPane(buffer: []u8, message: DetachPane) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.detach_pane), DetachPane, buffer, message);
}

pub fn encodeRequestTabSnapshot(
    buffer: []u8,
    message: RequestTabSnapshot,
) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.request_tab_snapshot),
        RequestTabSnapshot,
        buffer,
        message,
    );
}

pub fn encodeCreatePane(buffer: []u8, message: CreatePane) ![]const u8 {
    try validateRequestId(message.request_id);
    try message.size.validate();
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.create_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeTabLocation(&encoder, message.location);
    try encodeSize(&encoder, message.size);
    try encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn encodeClosePane(buffer: []u8, message: ClosePane) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.close_pane), ClosePane, buffer, message);
}

pub fn encodeRequestWorkspaceSnapshot(
    buffer: []u8,
    message: RequestWorkspaceSnapshot,
) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.request_workspace_snapshot),
        RequestWorkspaceSnapshot,
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
    try encodeLaunch(&encoder, message.launch);
    return encoder.finish();
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

pub fn encodeCloseTab(buffer: []u8, message: CloseTab) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.close_tab), CloseTab, buffer, message);
}

pub fn encodeMoveTab(buffer: []u8, message: MoveTab) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.move_tab), MoveTab, buffer, message);
}

pub fn encodeQueryHistory(buffer: []u8, message: QueryHistory) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.query, max_history_query_bytes, true);
    if (message.limit == 0 or message.limit > max_history_results)
        return error.InvalidHistoryLimit;
    switch (message.scope) {
        .global => if (message.scope_value.len != 0 or message.pane_id != .invalid)
            return error.InvalidHistoryScope,
        .cwd, .workspace => {
            try validateBytes(message.scope_value, max_cwd_bytes, false);
            if (message.pane_id != .invalid) return error.InvalidHistoryScope;
        },
        .pane => {
            try validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) return error.InvalidHistoryScope;
        },
    }
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.query_history));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeSized16(message.query);
    try encoder.writeByte(@intFromEnum(message.scope));
    switch (message.scope) {
        .global => {},
        .cwd, .workspace => try encoder.writeSized16(message.scope_value),
        .pane => try encoder.writeInt(u64, id.raw(message.pane_id)),
    }
    try encoder.writeByte(@intFromBool(message.failed_only));
    try encoder.writeInt(u16, message.limit);
    return encoder.finish();
}

pub fn encodeRuntimeStop(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.runtime_stop));
    return encoder.finish();
}

pub fn encodeRequestGraphicsSnapshot(
    buffer: []u8,
    message: RequestGraphicsSnapshot,
) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.request_graphics_snapshot),
        RequestGraphicsSnapshot,
        buffer,
        message,
    );
}

pub fn decodeClient(payload: []const u8) !ClientMessage {
    var decoder = wire.Decoder.init(payload);
    const tag = try decodeTag(ClientTag, try decoder.readByte());
    const message: ClientMessage = switch (tag) {
        .open_pane => .{ .open_pane = try decodeOpenPane(&decoder) },
        .pane_input => .{ .pane_input = try decodePaneInput(&decoder) },
        .pane_resize => .{ .pane_resize = try Derived(PaneResize).decode(&decoder) },
        .frame_ack => .{ .frame_ack = try Derived(FrameAck).decode(&decoder) },
        .request_snapshot => .{ .request_snapshot = try Derived(RequestSnapshot).decode(&decoder) },
        .detach_pane => .{ .detach_pane = try Derived(DetachPane).decode(&decoder) },
        .runtime_stop => .{ .runtime_stop = {} },
        .request_tab_snapshot => .{
            .request_tab_snapshot = try Derived(RequestTabSnapshot).decode(&decoder),
        },
        .create_pane => .{ .create_pane = try decodeCreatePane(&decoder) },
        .close_pane => .{ .close_pane = try Derived(ClosePane).decode(&decoder) },
        .query_history => .{ .query_history = try decodeQueryHistory(&decoder) },
        .request_workspace_snapshot => .{
            .request_workspace_snapshot = try Derived(RequestWorkspaceSnapshot).decode(&decoder),
        },
        .create_tab => .{ .create_tab = try decodeCreateTab(&decoder) },
        .rename_tab => .{ .rename_tab = try decodeRenameTab(&decoder) },
        .close_tab => .{ .close_tab = try Derived(CloseTab).decode(&decoder) },
        .move_tab => .{ .move_tab = try Derived(MoveTab).decode(&decoder) },
        .request_graphics_snapshot => .{
            .request_graphics_snapshot = try Derived(RequestGraphicsSnapshot).decode(&decoder),
        },
        .graphics_credit => .{
            .graphics_credit = try Derived(GraphicsCredit).decode(&decoder),
        },
        .configure_graphics => .{
            .configure_graphics = try Derived(ConfigureGraphics).decode(&decoder),
        },
        .request_runtime_state => .{ .request_runtime_state = {} },
        .create_workspace => .{ .create_workspace = try decodeCreateWorkspace(&decoder) },
        .rename_workspace => .{ .rename_workspace = try decodeRenameWorkspace(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

pub fn encodePaneOpened(buffer: []u8, message: PaneOpened) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.pane_opened), PaneOpened, buffer, message);
}

pub fn encodePaneFrame(buffer: []u8, message: frame.Frame) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_frame));
    try frame.encodeBody(&encoder, message);
    return encoder.finish();
}

pub fn encodePaneExited(buffer: []u8, message: PaneExited) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.pane_exited), PaneExited, buffer, message);
}

pub fn encodePaneCwd(buffer: []u8, message: PaneCwd) ![]const u8 {
    try validatePaneId(message.pane_id);
    try validateBytes(message.cwd, max_cwd_bytes, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_cwd));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.cwd);
    return encoder.finish();
}

pub fn encodeRequestFailed(buffer: []u8, message: RequestFailed) ![]const u8 {
    try validateErrorMessage(message.message);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.request_failed));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u16, @intFromEnum(message.code));
    try encoder.writeBytes(message.message);
    return encoder.finish();
}

pub fn encodeRuntimeStopping(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.runtime_stopping));
    return encoder.finish();
}

pub fn encodeGraphicsSnapshot(buffer: []u8, message: graphics.Snapshot) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_snapshot));
    try graphics.encodeSnapshot(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsImage(buffer: []u8, message: graphics.Image) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_image));
    try graphics.encodeImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsSharedImage(buffer: []u8, message: graphics.SharedImage) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_shared_image));
    try graphics.encodeSharedImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsImageChunk(buffer: []u8, message: graphics.ImageChunk) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_image_chunk));
    try graphics.encodeImageChunk(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsPlacement(buffer: []u8, message: graphics.Placement) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_placement));
    try graphics.encodePlacement(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsDeleteImage(buffer: []u8, message: graphics.DeleteImage) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_delete_image));
    try graphics.encodeDeleteImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsDeletePlacement(buffer: []u8, message: graphics.DeletePlacement) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_delete_placement));
    try graphics.encodeDeletePlacement(&encoder, message);
    return encoder.finish();
}

pub fn encodeProxyStatus(buffer: []u8, message: ProxyStatus) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.proxy_status), ProxyStatus, buffer, message);
}

pub fn encodeAgentSnapshot(buffer: []u8, message: AgentSnapshot) ![]const u8 {
    if (message.revision == 0) return error.InvalidAgentRevision;
    if (message.entries.len > max_agent_snapshot_entries) return error.TooManyAgentEntries;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.agent_snapshot));
    try encoder.writeInt(u64, message.revision);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries, 0..) |entry, index| {
        for (message.entries[0..index]) |previous| {
            if (previous.pane_id == entry.pane_id and
                previous.pane_generation == entry.pane_generation)
                return error.DuplicateAgentEntry;
        }
        try encodeAgentSnapshotEntry(&encoder, entry);
    }
    return encoder.finish();
}

pub fn encodeSystemMetrics(buffer: []u8, message: SystemMetrics) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.system_metrics), SystemMetrics, buffer, message);
}

pub fn encodeWorkspaceList(buffer: []u8, message: WorkspaceList) ![]const u8 {
    if (message.revision == 0) return error.InvalidWorkspaceListRevision;
    if (message.entries.len > max_workspace_list_entries) return error.TooManyWorkspaces;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.workspace_list));
    try encoder.writeInt(u64, message.revision);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries, 0..) |entry, index| {
        if (entry.workspace == .invalid) return error.InvalidWorkspaceId;
        try validateBytes(entry.name, max_workspace_name_bytes, false);
        try validateBytes(entry.path, max_cwd_bytes, false);
        if (entry.tab_count > max_tabs_per_workspace) return error.TooManyTabs;
        for (message.entries[0..index]) |previous| {
            if (previous.workspace == entry.workspace) return error.DuplicateWorkspace;
        }
        try encoder.writeInt(u64, id.raw(entry.workspace));
        try encoder.writeSized16(entry.name);
        try encoder.writeSized16(entry.path);
        try encoder.writeInt(u16, entry.tab_count);
    }
    return encoder.finish();
}

pub fn encodeTabSnapshot(buffer: []u8, message: TabSnapshot) ![]const u8 {
    try validateRequestId(message.request_id);
    if (message.panes.len > max_panes_per_tab) return error.TooManyPanes;

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.tab_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeTabLocation(&encoder, message.location);
    try encoder.writeInt(u16, @intCast(message.panes.len));
    for (message.panes, 0..) |pane, pane_index| {
        try validatePaneId(pane.pane_id);
        for (message.panes[0..pane_index]) |previous| {
            if (previous.pane_id == pane.pane_id) return error.DuplicatePane;
        }
        try encoder.writeInt(u64, id.raw(pane.pane_id));
        try encoder.writeByte(@intFromEnum(pane.lifecycle));
    }
    return encoder.finish();
}

pub fn encodeWorkspaceSnapshot(buffer: []u8, message: WorkspaceSnapshot) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.name, max_workspace_name_bytes, false);
    if (message.tabs.len > max_tabs_per_workspace) return error.TooManyTabs;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.workspace_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeWorkspaceLocation(&encoder, message.workspace);
    try encoder.writeSized16(message.name);
    try encoder.writeInt(u16, @intCast(message.tabs.len));
    for (message.tabs, 0..) |tab, index| {
        if (tab.tab_id == .invalid) return error.InvalidTabId;
        if (tab.position != index) return error.InvalidTabPosition;
        if (tab.pane_count > max_panes_per_tab) return error.TooManyPanes;
        try validateTabLabel(tab.label, false);
        try encoder.writeInt(u64, id.raw(tab.tab_id));
        try encoder.writeInt(u16, tab.position);
        try encoder.writeInt(u16, tab.pane_count);
        try encoder.writeSized16(tab.label);
    }
    return encoder.finish();
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

pub fn encodeTabClosed(buffer: []u8, message: TabClosed) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.tab_closed), TabClosed, buffer, message);
}

pub fn encodeTabMoved(buffer: []u8, message: TabMoved) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.tab_moved), TabMoved, buffer, message);
}

pub fn encodeResyncRequired(buffer: []u8, message: ResyncRequired) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ServerTag.resync_required),
        ResyncRequired,
        buffer,
        message,
    );
}

pub fn encodeHistoryResults(buffer: []u8, message: HistoryResults) ![]const u8 {
    try validateRequestId(message.request_id);
    if (message.entries.len > max_history_results) return error.TooManyHistoryResults;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.history_results));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries) |entry| try encodeHistoryEntry(&encoder, entry);
    return encoder.finish();
}

pub fn decodeServer(payload: []const u8) !ServerMessage {
    var decoder = wire.Decoder.init(payload);
    const tag = try decodeTag(ServerTag, try decoder.readByte());
    const message: ServerMessage = switch (tag) {
        .pane_opened => .{ .pane_opened = try Derived(PaneOpened).decode(&decoder) },
        .pane_frame => .{ .pane_frame = try frame.decodeBody(&decoder) },
        .pane_exited => .{ .pane_exited = try Derived(PaneExited).decode(&decoder) },
        .request_failed => .{ .request_failed = try decodeRequestFailed(&decoder) },
        .runtime_stopping => .{ .runtime_stopping = {} },
        .tab_snapshot => .{
            .tab_snapshot = try decodeTabSnapshot(&decoder),
        },
        .history_results => .{ .history_results = try decodeHistoryResults(&decoder) },
        .workspace_snapshot => .{
            .workspace_snapshot = try decodeWorkspaceSnapshot(&decoder),
        },
        .tab_created => .{ .tab_created = try decodeTabCreated(&decoder) },
        .tab_renamed => .{ .tab_renamed = try decodeTabRenamed(&decoder) },
        .tab_closed => .{ .tab_closed = try Derived(TabClosed).decode(&decoder) },
        .tab_moved => .{ .tab_moved = try Derived(TabMoved).decode(&decoder) },
        .graphics_snapshot => .{ .graphics_snapshot = try graphics.decodeSnapshot(&decoder) },
        .graphics_image => .{ .graphics_image = try graphics.decodeImage(&decoder) },
        .graphics_image_chunk => .{ .graphics_image_chunk = try graphics.decodeImageChunk(&decoder) },
        .graphics_placement => .{ .graphics_placement = try graphics.decodePlacement(&decoder) },
        .graphics_delete_image => .{ .graphics_delete_image = try graphics.decodeDeleteImage(&decoder) },
        .graphics_delete_placement => .{ .graphics_delete_placement = try graphics.decodeDeletePlacement(&decoder) },
        .resync_required => .{ .resync_required = try Derived(ResyncRequired).decode(&decoder) },
        .graphics_shared_image => .{ .graphics_shared_image = try graphics.decodeSharedImage(&decoder) },
        .proxy_status => .{ .proxy_status = try Derived(ProxyStatus).decode(&decoder) },
        .agent_snapshot => .{ .agent_snapshot = try decodeAgentSnapshot(&decoder) },
        .system_metrics => .{ .system_metrics = try Derived(SystemMetrics).decode(&decoder) },
        .workspace_list => .{ .workspace_list = try decodeWorkspaceList(&decoder) },
        .pane_cwd => .{ .pane_cwd = try decodePaneCwd(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

fn encodeLaunch(encoder: *wire.Encoder, launch: Launch) !void {
    try validateBytes(launch.cwd, max_cwd_bytes, false);
    if (launch.arguments.len == 0 or launch.arguments.len > max_argument_count)
        return error.InvalidArgumentCount;
    if (launch.environment.len > max_environment_count)
        return error.TooManyEnvironmentEntries;

    try encoder.writeSized16(launch.cwd);
    try encoder.writeInt(u16, @intCast(launch.arguments.len));
    var argument_bytes: usize = 0;
    for (launch.arguments, 0..) |argument, index| {
        try validateBytes(argument, std.math.maxInt(u16), index != 0);
        argument_bytes = std.math.add(usize, argument_bytes, argument.len) catch
            return error.ArgumentsTooLarge;
        if (argument_bytes > max_argument_bytes) return error.ArgumentsTooLarge;
        try encoder.writeSized16(argument);
    }

    try encoder.writeByte(@intFromEnum(launch.environment_mode));
    try encoder.writeInt(u16, @intCast(launch.environment.len));
    var environment_bytes: usize = 0;
    for (launch.environment) |entry| {
        try validateEnvironmentEntry(entry);
        environment_bytes = std.math.add(usize, environment_bytes, entry.name.len) catch
            return error.EnvironmentTooLarge;
        environment_bytes = std.math.add(usize, environment_bytes, entry.value.len) catch
            return error.EnvironmentTooLarge;
        if (environment_bytes > max_environment_bytes) return error.EnvironmentTooLarge;
        try encoder.writeSized16(entry.name);
        try encoder.writeSized32(entry.value);
    }
}

fn decodeOpenPane(decoder: *wire.Decoder) !OpenPaneView {
    const request_id = try id.request(try decoder.readInt(u64));
    const target_tag = try decoder.readByte();
    const target: PaneTarget = switch (target_tag) {
        0 => .default,
        1 => pane: {
            const pane_id = try id.pane(try decoder.readInt(u64));
            break :pane .{ .pane = pane_id };
        },
        2 => workspace: {
            const workspace_id = try id.workspace(try decoder.readInt(u64));
            break :workspace .{ .workspace = workspace_id };
        },
        else => return error.InvalidPaneTarget,
    };
    const size = try decodeSize(decoder);
    const launch = switch (target) {
        .default => try decodeLaunch(decoder),
        .pane, .workspace => null,
    };
    return .{ .request_id = request_id, .target = target, .size = size, .launch = launch };
}

fn decodeCreateWorkspace(decoder: *wire.Decoder) !CreateWorkspaceView {
    const request_id = try id.request(try decoder.readInt(u64));
    const size = try decodeSize(decoder);
    const name = try decoder.readSized16();
    try validateTabLabel(name, false);
    return .{
        .request_id = request_id,
        .size = size,
        .name = name,
        .launch = try decodeLaunch(decoder),
    };
}

fn decodeLaunch(decoder: *wire.Decoder) !LaunchView {
    // Structural walk only: field boundaries and byte budgets, so every wire
    // length is checked before a consumer allocates from it. Content rules
    // (embedded NULs, '=' in names) are enforced by the iterators as the
    // consumer decodes each item, so items are only scanned once.
    const cwd = try decoder.readSized16();
    try validateBytes(cwd, max_cwd_bytes, false);

    const argument_count = try decoder.readInt(u16);
    if (argument_count == 0 or argument_count > max_argument_count)
        return error.InvalidArgumentCount;
    const arguments_start = decoder.index;
    var argument_bytes: usize = 0;
    for (0..argument_count) |_| {
        const argument = try decoder.readSized16();
        argument_bytes += argument.len;
        if (argument_bytes > max_argument_bytes) return error.ArgumentsTooLarge;
    }
    const encoded_arguments = decoder.consumed(arguments_start);

    const environment_mode = try decodeEnvironmentMode(try decoder.readByte());
    const environment_count = try decoder.readInt(u16);
    if (environment_count > max_environment_count) return error.TooManyEnvironmentEntries;
    const environment_start = decoder.index;
    var environment_bytes: usize = 0;
    for (0..environment_count) |_| {
        environment_bytes += (try decoder.readSized16()).len;
        environment_bytes += (try decoder.readSized32()).len;
        if (environment_bytes > max_environment_bytes) return error.EnvironmentTooLarge;
    }
    return .{
        .cwd = cwd,
        .argument_count = argument_count,
        .encoded_arguments = encoded_arguments,
        .environment_mode = environment_mode,
        .environment_count = environment_count,
        .encoded_environment = decoder.consumed(environment_start),
    };
}

fn decodePaneInput(decoder: *wire.Decoder) !PaneInput {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const bytes = try decoder.readBytes(decoder.bytes.len - decoder.index);
    if (bytes.len == 0 or bytes.len > max_input_bytes) return error.InvalidInputLength;
    return .{ .pane_id = pane_id, .bytes = bytes };
}

fn decodePaneCwd(decoder: *wire.Decoder) !PaneCwd {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const cwd = try decoder.readSized16();
    try validateBytes(cwd, max_cwd_bytes, false);
    return .{ .pane_id = pane_id, .cwd = cwd };
}

fn decodeCreatePane(decoder: *wire.Decoder) !CreatePaneView {
    return .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .location = try decodeTabLocation(decoder),
        .size = try decodeSize(decoder),
        .launch = try decodeLaunch(decoder),
    };
}

fn decodeCreateTab(decoder: *wire.Decoder) !CreateTabView {
    const request_id = try id.request(try decoder.readInt(u64));
    const workspace = try decodeWorkspaceLocation(decoder);
    const label = try decoder.readSized16();
    try validateTabLabel(label, true);
    return .{
        .request_id = request_id,
        .workspace = workspace,
        .label = label,
        .size = try decodeSize(decoder),
        .launch = try decodeLaunch(decoder),
    };
}

fn decodeRenameTab(decoder: *wire.Decoder) !RenameTab {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeTabLocation(decoder);
    const label = try decoder.readSized16();
    try validateTabLabel(label, false);
    return .{ .request_id = request_id, .location = location, .label = label };
}

fn decodeRenameWorkspace(decoder: *wire.Decoder) !RenameWorkspace {
    const request_id = try id.request(try decoder.readInt(u64));
    const workspace = try decodeWorkspaceLocation(decoder);
    const name = try decoder.readSized16();
    try validateTabLabel(name, false);
    return .{ .request_id = request_id, .workspace = workspace, .name = name };
}

fn decodeQueryHistory(decoder: *wire.Decoder) !QueryHistory {
    const request_id = try id.request(try decoder.readInt(u64));
    const query = try decoder.readSized16();
    try validateBytes(query, max_history_query_bytes, true);
    const scope = try decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try validateBytes(scope_value, max_cwd_bytes, false);
        },
        .pane => pane_id = try id.pane(try decoder.readInt(u64)),
    }
    const failed_only = try decoder.readBool();
    const limit = try decoder.readInt(u16);
    if (limit == 0 or limit > max_history_results) return error.InvalidHistoryLimit;
    return .{
        .request_id = request_id,
        .query = query,
        .scope = scope,
        .scope_value = scope_value,
        .pane_id = pane_id,
        .failed_only = failed_only,
        .limit = limit,
    };
}

fn decodeRequestFailed(decoder: *wire.Decoder) !RequestFailed {
    const request_id: RequestId = @enumFromInt(try decoder.readInt(u64));
    const code = try decodeFailureCode(try decoder.readInt(u16));
    const message = try decoder.readBytes(decoder.bytes.len - decoder.index);
    try validateErrorMessage(message);
    return .{ .request_id = request_id, .code = code, .message = message };
}

fn decodeTabSnapshot(decoder: *wire.Decoder) !TabSnapshotView {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeTabLocation(decoder);
    const pane_count = try decoder.readInt(u16);
    if (pane_count > max_panes_per_tab) return error.TooManyPanes;

    const panes_start = decoder.index;
    // Quadratic duplicate scan, acceptable while max_panes_per_tab is 64;
    // revisit before raising the limit.
    var seen: [max_panes_per_tab]PaneId = undefined;
    for (0..pane_count) |pane_index| {
        const pane_id = try id.pane(try decoder.readInt(u64));
        _ = try decodePaneLifecycle(try decoder.readByte());
        for (seen[0..pane_index]) |previous| {
            if (previous == pane_id) return error.DuplicatePane;
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

fn decodeWorkspaceSnapshot(decoder: *wire.Decoder) !WorkspaceSnapshotView {
    const request_id = try id.request(try decoder.readInt(u64));
    const workspace = try decodeWorkspaceLocation(decoder);
    const name = try decoder.readSized16();
    try validateBytes(name, max_workspace_name_bytes, false);
    const tab_count = try decoder.readInt(u16);
    if (tab_count > max_tabs_per_workspace) return error.InvalidTabCount;
    const tabs_start = decoder.index;
    var seen: [max_tabs_per_workspace]TabId = undefined;
    for (0..tab_count) |index| {
        const tab_id = try id.tab(try decoder.readInt(u64));
        const position = try decoder.readInt(u16);
        if (position != index) return error.InvalidTabPosition;
        const pane_count = try decoder.readInt(u16);
        if (pane_count > max_panes_per_tab) return error.TooManyPanes;
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

fn decodeTabCreated(decoder: *wire.Decoder) !TabCreated {
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

fn decodeTabRenamed(decoder: *wire.Decoder) !TabRenamed {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodeTabLocation(decoder);
    const label = try decoder.readSized16();
    try validateTabLabel(label, false);
    return .{ .request_id = request_id, .location = location, .label = label };
}

fn encodeHistoryEntry(encoder: *wire.Encoder, entry: HistoryEntry) !void {
    if (entry.id == 0) return error.InvalidHistoryId;
    try validatePaneId(entry.pane_id);
    try validateBytes(entry.command, max_history_command_bytes, false);
    try validateBytes(entry.cwd, max_cwd_bytes, false);
    try validateBytes(entry.workspace_path, max_cwd_bytes, false);
    try encoder.writeInt(u64, entry.id);
    try encoder.writeInt(u64, id.raw(entry.pane_id));
    try encoder.writeInt(i64, entry.started_at_ms);
    try encoder.writeInt(i64, entry.duration_ns);
    if (entry.exit_code) |exit_code| {
        try encoder.writeByte(1);
        try encoder.writeInt(i32, exit_code);
    } else {
        try encoder.writeByte(0);
    }
    try encoder.writeByte(@intFromEnum(entry.status));
    try encoder.writeSized32(entry.command);
    try encoder.writeSized16(entry.cwd);
    try encoder.writeSized16(entry.workspace_path);
}

fn decodeHistoryEntry(decoder: *wire.Decoder) !HistoryEntry {
    const history_id = try decoder.readInt(u64);
    if (history_id == 0) return error.InvalidHistoryId;
    const pane_id = try id.pane(try decoder.readInt(u64));
    const started_at_ms = try decoder.readInt(i64);
    const duration_ns = try decoder.readInt(i64);
    const exit_code = if (try decoder.readBool())
        try decoder.readInt(i32)
    else
        null;
    const status = try decodeHistoryStatus(try decoder.readByte());
    const command = try decoder.readSized32();
    const cwd = try decoder.readSized16();
    const workspace_path = try decoder.readSized16();
    try validateBytes(command, max_history_command_bytes, false);
    try validateBytes(cwd, max_cwd_bytes, false);
    try validateBytes(workspace_path, max_cwd_bytes, false);
    return .{
        .id = history_id,
        .pane_id = pane_id,
        .started_at_ms = started_at_ms,
        .duration_ns = duration_ns,
        .exit_code = exit_code,
        .status = status,
        .command = command,
        .cwd = cwd,
        .workspace_path = workspace_path,
    };
}

fn decodeHistoryResults(decoder: *wire.Decoder) !HistoryResultsView {
    const request_id = try id.request(try decoder.readInt(u64));
    const entry_count = try decoder.readInt(u16);
    if (entry_count > max_history_results) return error.TooManyHistoryResults;
    const entries_start = decoder.index;
    for (0..entry_count) |_| try skipHistoryEntry(decoder);
    return .{
        .request_id = request_id,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
}

fn encodeAgentSnapshotEntry(encoder: *wire.Encoder, entry: AgentSnapshotEntry) !void {
    try validatePaneId(entry.pane_id);
    if (entry.pane_generation == 0 or entry.sequence == 0 or entry.confidence > 100)
        return error.InvalidAgentEntry;
    if (entry.expires_at_ms < entry.observed_at_ms) return error.InvalidAgentExpiry;
    try encoder.writeInt(u64, id.raw(entry.pane_id));
    try encoder.writeInt(u64, entry.pane_generation);
    try encoder.writeInt(u32, entry.process_id);
    try encoder.writeBytes(&entry.session_id);
    try encoder.writeByte(@intFromEnum(entry.provider));
    try encoder.writeByte(@intFromEnum(entry.status));
    try encoder.writeByte(@intFromEnum(entry.source));
    try encoder.writeByte(@intFromEnum(entry.authority));
    try encoder.writeByte(entry.confidence);
    try encoder.writeInt(u64, entry.sequence);
    try encoder.writeInt(i64, entry.observed_at_ms);
    try encoder.writeInt(i64, entry.expires_at_ms);
}

fn decodeAgentSnapshotEntry(decoder: *wire.Decoder) !AgentSnapshotEntry {
    const entry: AgentSnapshotEntry = .{
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .process_id = try decoder.readInt(u32),
        .session_id = (try decoder.readBytes(16))[0..16].*,
        .provider = std.enums.fromInt(AgentProvider, try decoder.readByte()) orelse
            return error.InvalidAgentProvider,
        .status = std.enums.fromInt(AgentStatus, try decoder.readByte()) orelse
            return error.InvalidAgentStatus,
        .source = std.enums.fromInt(AgentSource, try decoder.readByte()) orelse
            return error.InvalidAgentSource,
        .authority = std.enums.fromInt(AgentAuthority, try decoder.readByte()) orelse
            return error.InvalidAgentAuthority,
        .confidence = try decoder.readByte(),
        .sequence = try decoder.readInt(u64),
        .observed_at_ms = try decoder.readInt(i64),
        .expires_at_ms = try decoder.readInt(i64),
    };
    if (entry.pane_generation == 0 or entry.sequence == 0 or entry.confidence > 100)
        return error.InvalidAgentEntry;
    if (entry.expires_at_ms < entry.observed_at_ms) return error.InvalidAgentExpiry;
    return entry;
}

fn decodeWorkspaceListEntry(decoder: *wire.Decoder) !WorkspaceListEntry {
    const workspace = try id.workspace(try decoder.readInt(u64));
    const name = try decoder.readSized16();
    try validateBytes(name, max_workspace_name_bytes, false);
    const path = try decoder.readSized16();
    try validateBytes(path, max_cwd_bytes, false);
    const tab_count = try decoder.readInt(u16);
    if (tab_count > max_tabs_per_workspace) return error.TooManyTabs;
    return .{ .workspace = workspace, .name = name, .path = path, .tab_count = tab_count };
}

fn decodeWorkspaceList(decoder: *wire.Decoder) !WorkspaceListView {
    const revision = try decoder.readInt(u64);
    if (revision == 0) return error.InvalidWorkspaceListRevision;
    const entry_count = try decoder.readInt(u16);
    if (entry_count > max_workspace_list_entries) return error.TooManyWorkspaces;
    const entries_start = decoder.index;
    var seen: [max_workspace_list_entries]WorkspaceId = undefined;
    for (0..entry_count) |index| {
        const entry = try decodeWorkspaceListEntry(decoder);
        for (seen[0..index]) |previous| {
            if (previous == entry.workspace) return error.DuplicateWorkspace;
        }
        seen[index] = entry.workspace;
    }
    return .{
        .revision = revision,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
}

fn decodeAgentSnapshot(decoder: *wire.Decoder) !AgentSnapshotView {
    const revision = try decoder.readInt(u64);
    if (revision == 0) return error.InvalidAgentRevision;
    const entry_count = try decoder.readInt(u16);
    if (entry_count > max_agent_snapshot_entries) return error.TooManyAgentEntries;
    const entries_start = decoder.index;
    var seen_ids: [max_agent_snapshot_entries]PaneId = undefined;
    var seen_generations: [max_agent_snapshot_entries]u64 = undefined;
    for (0..entry_count) |index| {
        const entry = try decodeAgentSnapshotEntry(decoder);
        for (seen_ids[0..index], seen_generations[0..index]) |pane_id, generation| {
            if (pane_id == entry.pane_id and generation == entry.pane_generation)
                return error.DuplicateAgentEntry;
        }
        seen_ids[index] = entry.pane_id;
        seen_generations[index] = entry.pane_generation;
    }
    return .{
        .revision = revision,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
}

/// Walks one entry's field boundaries and byte budgets without scanning its
/// content; `HistoryEntryIterator` validates content as the consumer decodes.
fn skipHistoryEntry(decoder: *wire.Decoder) !void {
    _ = try decoder.readInt(u64); // id
    _ = try decoder.readInt(u64); // pane_id
    _ = try decoder.readInt(i64); // started_at_ms
    _ = try decoder.readInt(i64); // duration_ns
    if (try decoder.readBool()) _ = try decoder.readInt(i32);
    _ = try decoder.readByte(); // status
    if ((try decoder.readSized32()).len > max_history_command_bytes)
        return error.InvalidByteString;
    if ((try decoder.readSized16()).len > max_cwd_bytes) return error.InvalidByteString;
    if ((try decoder.readSized16()).len > max_cwd_bytes) return error.InvalidByteString;
}

fn decodeTag(comptime Tag: type, value: u8) error{UnknownMessage}!Tag {
    return std.enums.fromInt(Tag, value) orelse error.UnknownMessage;
}
