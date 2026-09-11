//! Value contracts used by the ClientModel aggregate.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const attachments = @import("../attachments/root.zig");
const bars = @import("../bars/root.zig");
const lua_config = @import("../config/root.zig");
const graphics = @import("../environment/root.zig");
const input_capability = @import("../input/root.zig");
const link_capability = @import("../links/root.zig");
const notifications = @import("../notifications/root.zig");
const frontend_ui = @import("../layout/root.zig");
const workspace_capability = @import("../workspace/root.zig");

pub const copy_mode = input_capability.copy_mode;
const keybind = input_capability;
pub const capability_support = graphics;
pub const schema = core.schema;
pub const layout_mod = workspace_capability.layout;
pub const multiplexer = workspace_capability.multiplexer;
pub const tabs_mod = workspace_capability.tabs;
const workspace_list_mod = workspace_capability.workspace_list;
pub const ui = core.ui;

pub const Version = @import("Version.zig");

pub const Change = enum {
    unchanged,
    changed,
};

pub const TabSelection = @import("TabSelection.zig");

pub const TabSelectionTarget = union(enum) {
    tab_id: schema.TabId,
    offset: isize,
    position: usize,
};

pub const RenameTab = @import("RenameTab.zig");

pub const NewTab = @import("NewTab.zig");

pub const TabCreation = @import("TabCreation.zig");

pub const TabCreationPlan = @import("TabCreationPlan.zig");

pub const WorkspaceBookmark = @import("WorkspaceBookmark.zig");

pub const WorkspaceDeparture = @import("WorkspaceDeparture.zig");

pub const WorkspaceArrival = @import("WorkspaceArrival.zig");

pub const WorkspaceActivation = @import("WorkspaceActivation.zig");

pub const WorkspaceReplacement = @import("WorkspaceReplacement.zig");

pub const WorkspaceActivationSeed = @import("WorkspaceActivationSeed.zig");

pub const PaneAttachment = @import("PaneAttachment.zig");

pub const PaneAttachmentConfirmation = enum {
    confirmed,
    stale,
};

pub const TabDetachmentPlan = @import("TabDetachmentPlan.zig");

pub const PaneFocusTarget = union(enum) {
    pane_id: schema.PaneId,
    direction: layout_mod.Direction,
};

pub const PaneFocusRequest = @import("PaneFocusRequest.zig");

pub const PaneFocus = @import("PaneFocus.zig");

pub const ReportedPaneFocus = @import("ReportedPaneFocus.zig");

pub const PaneFocusReportTransition = @import("PaneFocusReportTransition.zig");

pub const ResizePaneRequest = @import("ResizePaneRequest.zig");

pub const PaneGeometryChange = @import("PaneGeometryChange.zig");

pub const TogglePaneFullscreenRequest = @import("TogglePaneFullscreenRequest.zig");

pub const SidebarLayout = @import("SidebarLayout.zig");

pub const SidebarAnimationChange = @import("SidebarAnimationChange.zig");

pub const ConfigurationInput = @import("ConfigurationInput.zig");

pub const max_window_title_template_bytes = 128;

pub const ConfigurationCommit = @import("ConfigurationCommit.zig");

pub const BarUpdateCommit = @import("BarUpdateCommit.zig");

pub const BarUpdateInput = @import("BarUpdateInput.zig");

pub const PluginExecutionId = enum(u64) {
    none = 0,
    _,
};

pub const PluginExecution = @import("PluginExecution.zig");

pub const ClipboardCaptureId = enum(u64) {
    none = 0,
    _,
};

pub const ClipboardCapture = @import("ClipboardCapture.zig");

pub const InitialClientState = @import("InitialClientState.zig");

pub const HostAppearance = enum { unknown, light, dark };

pub const HostCapabilities = @import("HostCapabilities.zig");

pub const HostCapabilitySupport = enum { unsupported, supported };

pub const HostCapabilityObservation = union(enum) {
    images: HostCapabilitySupport,
    window_pixels: PixelSize,
    cell_pixels: PixelSize,
    pointer_pixels: HostCapabilitySupport,
    foreground: struct { r: u8, g: u8, b: u8 },
    background: struct { r: u8, g: u8, b: u8 },
};

pub fn observedSupport(support: HostCapabilitySupport) capability_support.Support {
    return switch (support) {
        .unsupported => .unsupported,
        .supported => .supported,
    };
}

pub const PixelSize = @import("PixelSize.zig");

pub const HostUpdate = @import("HostUpdate.zig");

pub const HostCapabilitiesChange = @import("HostCapabilitiesChange.zig");

pub const HostResizeCommit = @import("HostResizeCommit.zig");

pub const HostCommit = @import("HostCommit.zig");

pub const WorkspaceListCollapse = @import("WorkspaceListCollapse.zig");

pub const WorkspaceListCommit = @import("WorkspaceListCommit.zig");

pub const ProxyStatusCommit = @import("ProxyStatusCommit.zig");

pub const SystemMetrics = @import("SystemMetrics.zig");

pub const SystemMetricsCommit = @import("SystemMetricsCommit.zig");

pub const NotificationPublication = @import("NotificationPublication.zig");

pub const NotificationChange = @import("NotificationChange.zig");

pub const NotificationActivation = @import("NotificationActivation.zig");

pub const AgentStatusChange = @import("AgentStatusChange.zig");

pub const AgentStatusChanges = @import("AgentStatusChanges.zig");

pub const AgentSnapshotCommit = @import("AgentSnapshotCommit.zig");

pub const LocalAgentNavigation = @import("LocalAgentNavigation.zig");

pub const AgentHandoff = @import("AgentHandoff.zig");

pub const AgentNavigationPlan = union(enum) {
    local: LocalAgentNavigation,
    handoff: AgentHandoff,
};

pub const PanePasteSession = @import("PanePasteSession.zig");

pub const PaneInputTarget = union(enum) {
    focused,
    pane: schema.PaneId,
    key_lease: schema.PaneId,
    paste_session: PanePasteSession,
};

pub const PaneInputPlan = @import("PaneInputPlan.zig");

pub const PaneFrameRecovery = @import("PaneFrameRecovery.zig");

pub const PaneFrameCommit = @import("PaneFrameCommit.zig");

pub const PaneFrameOutcome = union(enum) {
    detached,
    resync: PaneFrameRecovery,
    applied: PaneFrameCommit,
};

pub const PaneGraphicsFallbackCommit = @import("PaneGraphicsFallbackCommit.zig");

pub const PaneMetadataKind = enum {
    cwd,
    foreground,
    title,
};

pub const PaneMetadataCommand = union(PaneMetadataKind) {
    cwd: struct {
        pane_id: schema.PaneId,
        /// Borrowed only for the synchronous transition.
        path: []const u8,
    },
    foreground: struct {
        pane_id: schema.PaneId,
        /// Borrowed only for the synchronous transition.
        name: []const u8,
    },
    title: struct {
        pane_id: schema.PaneId,
        /// Borrowed only for the synchronous transition; empty clears it.
        title: []const u8,
    },
};

pub const PaneMetadataCommit = @import("PaneMetadataCommit.zig");

pub const PaneProgressCommit = @import("PaneProgressCommit.zig");

pub const PaneViewportTarget = union(enum) {
    absolute: u32,
    relative: i32,
    bottom,
};

pub const PaneViewportCommand = @import("PaneViewportCommand.zig");

pub const PaneViewportChange = @import("PaneViewportChange.zig");

pub const CopyModeCommand = union(enum) {
    key: keybind.Key,
    pointer: copy_mode.PointerMotion,
    cancel_pointer,
    vertical: i32,
    matches: CopyModeMatches,
    leave,
};

pub const CopyModeMatches = @import("CopyModeMatches.zig");

pub const CopyModeProjection = @import("CopyModeProjection.zig");

pub const CopyModeFrame = @import("CopyModeFrame.zig");

pub const CopyModePlan = @import("CopyModePlan.zig");

pub const CopyModeCommit = @import("CopyModeCommit.zig");

pub const RequestPaneSplit = @import("RequestPaneSplit.zig");

pub const PaneSplit = @import("PaneSplit.zig");

pub const PaneResize = schema.PaneResize;

pub const PaneSplitPlan = @import("PaneSplitPlan.zig");

pub const CommitPaneSplit = @import("CommitPaneSplit.zig");

pub const PaneSplitDisposition = enum {
    active,
    inactive,
    stale,
};

pub const PaneSplitCommit = @import("PaneSplitCommit.zig");

pub const PaneSplitCommitState = @import("PaneSplitCommitState.zig");

pub const RecoverPaneSplit = @import("RecoverPaneSplit.zig");

pub const PaneSplitRecovery = union(enum) {
    resize: PaneResize,
    not_required,
    stale,
};

pub const PaneClosure = @import("PaneClosure.zig");

pub const PaneRetirement = @import("PaneRetirement.zig");

pub const StalePaneExit = @import("StalePaneExit.zig");

pub const PaneExit = union(enum) {
    retired: PaneRetirement,
    stale: StalePaneExit,
};

pub const RemoveTab = @import("RemoveTab.zig");

pub const RemovedPanes = @import("RemovedPanes.zig");

pub const TabRemoval = @import("TabRemoval.zig");

pub const TabRemovalAbsence = enum {
    workspace,
    tab,
};

pub const StaleTabRemoval = @import("StaleTabRemoval.zig");

pub const TabRemovalCommit = union(enum) {
    removed: TabRemoval,
    stale: StaleTabRemoval,
};

pub const TabReconciliation = @import("TabReconciliation.zig");

pub const WorkspaceTabInput = tabs_mod.WorkspaceTabInput;
pub const WorkspaceSnapshot = tabs_mod.WorkspaceSnapshotInput;
pub const TabSnapshot = tabs_mod.PaneSnapshot;

pub const RemovedWorkspaceTabs = @import("RemovedWorkspaceTabs.zig");

pub const RemovedWorkspacePanes = @import("RemovedWorkspacePanes.zig");

pub const WorkspaceReconciliation = @import("WorkspaceReconciliation.zig");
