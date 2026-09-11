//! Passive state owned by one disposable client.

test {
    _ = @import("tests/root.zig");
}

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const attachments = @import("../attachments/root.zig");
const bars_capability = @import("../bars/root.zig");
const lua_config = @import("../config/root.zig");
const graphics = @import("../environment/root.zig");
const input_capability = @import("../input/root.zig");
const link_capability = @import("../links/root.zig");
const notifications = @import("../notifications/root.zig");
const frontend_ui = @import("../layout/root.zig");
const history_palette_mod = @import("history_palette.zig");
const suggestion_mod = @import("suggestion.zig");
pub const name_prompt = @import("name_prompt.zig");
const workspace_capability = @import("../workspace/root.zig");

pub const copy_mode = input_capability.copy_mode;
const keybind = input_capability;
const capability_support = graphics;
pub const schema = core.schema;
const layout_mod = workspace_capability.layout;
pub const navigation = workspace_capability.navigation;
pub const multiplexer = workspace_capability.multiplexer;
pub const tabs_mod = workspace_capability.tabs;
pub const workspace_list_mod = workspace_capability.workspace_list;
pub const ui = core.ui;

const model_types = @import("types.zig");

pub const Version = model_types.Version;
pub const Change = model_types.Change;
pub const TabSelection = model_types.TabSelection;
pub const TabSelectionTarget = model_types.TabSelectionTarget;
pub const RenameTab = model_types.RenameTab;
pub const NewTab = model_types.NewTab;
pub const TabCreation = model_types.TabCreation;
pub const TabCreationPlan = model_types.TabCreationPlan;
pub const WorkspaceBookmark = model_types.WorkspaceBookmark;
pub const WorkspaceDeparture = model_types.WorkspaceDeparture;
pub const WorkspaceArrival = model_types.WorkspaceArrival;
pub const WorkspaceActivation = model_types.WorkspaceActivation;
pub const WorkspaceReplacement = model_types.WorkspaceReplacement;
pub const WorkspaceActivationSeed = model_types.WorkspaceActivationSeed;
pub const PaneAttachment = model_types.PaneAttachment;
pub const PaneAttachmentConfirmation = model_types.PaneAttachmentConfirmation;
pub const TabDetachmentPlan = model_types.TabDetachmentPlan;
pub const PaneFocusTarget = model_types.PaneFocusTarget;
pub const PaneFocusRequest = model_types.PaneFocusRequest;
pub const PaneFocus = model_types.PaneFocus;
pub const ReportedPaneFocus = model_types.ReportedPaneFocus;
pub const PaneFocusReportTransition = model_types.PaneFocusReportTransition;
pub const ResizePaneRequest = model_types.ResizePaneRequest;
pub const PaneGeometryChange = model_types.PaneGeometryChange;
pub const TogglePaneFullscreenRequest = model_types.TogglePaneFullscreenRequest;
pub const SidebarLayout = model_types.SidebarLayout;
pub const SidebarAnimationChange = model_types.SidebarAnimationChange;
pub const ConfigurationInput = model_types.ConfigurationInput;
pub const ConfigurationCommit = model_types.ConfigurationCommit;
pub const BarUpdateCommit = model_types.BarUpdateCommit;
pub const BarUpdateInput = model_types.BarUpdateInput;
pub const PluginExecutionId = model_types.PluginExecutionId;
pub const PluginExecution = model_types.PluginExecution;
pub const ClipboardCaptureId = model_types.ClipboardCaptureId;
pub const ClipboardCapture = model_types.ClipboardCapture;
pub const InitialClientState = model_types.InitialClientState;
pub const HostCapabilities = model_types.HostCapabilities;
pub const HostCapabilitySupport = model_types.HostCapabilitySupport;
pub const HostCapabilityObservation = model_types.HostCapabilityObservation;
pub const PixelSize = model_types.PixelSize;
pub const HostUpdate = model_types.HostUpdate;
pub const HostCapabilitiesChange = model_types.HostCapabilitiesChange;
pub const HostResizeCommit = model_types.HostResizeCommit;
pub const HostCommit = model_types.HostCommit;
pub const WorkspaceListCollapse = model_types.WorkspaceListCollapse;
pub const WorkspaceListCommit = model_types.WorkspaceListCommit;
pub const ProxyStatusCommit = model_types.ProxyStatusCommit;
pub const SystemMetrics = model_types.SystemMetrics;
pub const SystemMetricsCommit = model_types.SystemMetricsCommit;
pub const NotificationPublication = model_types.NotificationPublication;
pub const NotificationChange = model_types.NotificationChange;
pub const NotificationActivation = model_types.NotificationActivation;
pub const AgentStatusChange = model_types.AgentStatusChange;
pub const AgentStatusChanges = model_types.AgentStatusChanges;
pub const AgentSnapshotCommit = model_types.AgentSnapshotCommit;
pub const LocalAgentNavigation = model_types.LocalAgentNavigation;
pub const AgentHandoff = model_types.AgentHandoff;
pub const AgentNavigationPlan = model_types.AgentNavigationPlan;
pub const PanePasteSession = model_types.PanePasteSession;
pub const PaneInputTarget = model_types.PaneInputTarget;
pub const PaneInputPlan = model_types.PaneInputPlan;
pub const PaneFrameRecovery = model_types.PaneFrameRecovery;
pub const PaneFrameCommit = model_types.PaneFrameCommit;
pub const PaneFrameOutcome = model_types.PaneFrameOutcome;
pub const PaneGraphicsFallbackCommit = model_types.PaneGraphicsFallbackCommit;
pub const PaneMetadataKind = model_types.PaneMetadataKind;
pub const PaneMetadataCommand = model_types.PaneMetadataCommand;
pub const PaneProgressCommit = model_types.PaneProgressCommit;
pub const PaneMetadataCommit = model_types.PaneMetadataCommit;
pub const PaneViewportTarget = model_types.PaneViewportTarget;
pub const PaneViewportCommand = model_types.PaneViewportCommand;
pub const PaneViewportChange = model_types.PaneViewportChange;
pub const CopyModeCommand = model_types.CopyModeCommand;
pub const HostAppearance = model_types.HostAppearance;
pub const CopyModeProjection = model_types.CopyModeProjection;
pub const CopyModeFrame = model_types.CopyModeFrame;
pub const CopyModePlan = model_types.CopyModePlan;
pub const CopyModeCommit = model_types.CopyModeCommit;
pub const RequestPaneSplit = model_types.RequestPaneSplit;
pub const PaneSplit = model_types.PaneSplit;
pub const PaneResize = model_types.PaneResize;
pub const PaneSplitPlan = model_types.PaneSplitPlan;
pub const CommitPaneSplit = model_types.CommitPaneSplit;
pub const PaneSplitDisposition = model_types.PaneSplitDisposition;
pub const PaneSplitCommit = model_types.PaneSplitCommit;
pub const PaneSplitCommitState = model_types.PaneSplitCommitState;
pub const RecoverPaneSplit = model_types.RecoverPaneSplit;
pub const PaneSplitRecovery = model_types.PaneSplitRecovery;
pub const PaneClosure = model_types.PaneClosure;
pub const PaneRetirement = model_types.PaneRetirement;
pub const StalePaneExit = model_types.StalePaneExit;
pub const PaneExit = model_types.PaneExit;
pub const RemoveTab = model_types.RemoveTab;
pub const RemovedPanes = model_types.RemovedPanes;
pub const TabRemoval = model_types.TabRemoval;
pub const TabRemovalAbsence = model_types.TabRemovalAbsence;
pub const StaleTabRemoval = model_types.StaleTabRemoval;
pub const TabRemovalCommit = model_types.TabRemovalCommit;
pub const TabReconciliation = model_types.TabReconciliation;
pub const WorkspaceTabInput = model_types.WorkspaceTabInput;
pub const WorkspaceSnapshot = model_types.WorkspaceSnapshot;
pub const TabSnapshot = model_types.TabSnapshot;
pub const RemovedWorkspaceTabs = model_types.RemovedWorkspaceTabs;
pub const RemovedWorkspacePanes = model_types.RemovedWorkspacePanes;
pub const WorkspaceReconciliation = model_types.WorkspaceReconciliation;

pub const HistoryPageResult = history_palette_mod.State.PageResult;

pub const PresentationMode = enum {
    normal,
    agent,
};

pub const Model = @import("Model.zig");

pub fn paneViewportOffset(pane: *const multiplexer.Pane, target: PaneViewportTarget) u32 {
    const maximum = pane.scroll.maxOffset(pane.buffer.h);

    return switch (target) {
        .absolute => |offset| @min(offset, maximum),
        .relative => |delta| @intCast(std.math.clamp(
            @as(i64, pane.scroll.offset) + @as(i64, delta),
            0,
            @as(i64, maximum),
        )),
        .bottom => maximum,
    };
}

pub fn commitPaneViewport(model: *Model, pane: *multiplexer.Pane, offset: u32) ?PaneViewportChange {
    if (pane.scroll.offset == offset) {
        return null;
    }

    pane.scroll.offset = offset;
    model.viewport_revision +%= 1;

    return .{
        .pane_id = pane.id,
        .offset = offset,
        .at_bottom = pane.scroll.atBottom(pane.buffer.h),
        .viewport_revision = model.viewport_revision,
    };
}

pub fn copyModeViewport(pane: *const multiplexer.Pane, wanted: u32) ?schema.SetPaneViewport {
    const offset = paneViewportOffset(pane, .{ .absolute = wanted });
    if (pane.scroll.offset == offset) {
        return null;
    }

    return .{ .pane_id = pane.id, .offset = offset };
}

pub fn releaseInvalidCopyMode(model: *Model) void {
    const state = model.copy_state orelse return;
    const active = model.workspace.activeConst() orelse {
        _ = model.releaseCopyMode(state.pane_id);
        return;
    };
    if (active.model.findConst(state.pane_id) != null) {
        return;
    }

    _ = model.releaseCopyMode(state.pane_id);
}

pub fn captureWorkspace(model: *Model) WorkspaceDeparture {
    const source = model.workspace.workspace orelse return .{};
    var departure: WorkspaceDeparture = .{ .source = source };
    if (model.workspace.activeConst()) |tab| {
        if (tab.model.focusedPaneConst()) |pane| {
            departure.bookmark = .{
                .location = tab.location,
                .pane_id = pane.id,
                .tab_layout = tab.model.layout,
            };
        }
    }

    var tabs = model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            departure.panes.append(pane.id);
        }
    }

    return departure;
}

const LaunchSource = @import("LaunchSource.zig");

pub fn focusedLaunchSource(model: *const Model) ?LaunchSource {
    const active = model.workspace.activeConst() orelse return null;
    const pane = active.model.focusedPaneConst() orelse return null;
    if (!pane.attached or !std.meta.eql(pane.location, active.location)) {
        return null;
    }

    return .{ .location = active.location, .pane_id = pane.id };
}

pub fn inheritCellSize(size: *schema.TerminalSize, source: schema.TerminalSize) void {
    size.cell_width_px = source.cell_width_px;
    size.cell_height_px = source.cell_height_px;
}

pub fn detachPane(pane: *multiplexer.Pane) void {
    pane.attached = false;
    pane.pending_frame_id = 0;
}

pub fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}

pub fn findTabConst(workspace: *const tabs_mod.Model, location: schema.TabLocation) ?*const tabs_mod.Tab {
    const index = workspace.indexOf(location.tab_id) orelse return null;
    const tab = &workspace.items[index].?;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}

test "resizing a mouse-selected pane cancels coordinates but retains gesture ownership" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    try std.testing.expect(model.beginPointerSelection(.{ .pane_id = pane_id, .position = .{ .x = 15, .y = 0 }, .now_ns = 0 }));
    const version = model.version();
    const pane = model.workspace.findPane(pane_id).?;
    try pane.buffer.resize(10, 5);

    try std.testing.expect(model.reconcileCopyModeFrame(.{ .pane_id = pane_id, .previous_offset = 0, .scroll = pane.scroll }));
    try std.testing.expect(model.copyModeProjection() == null);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
    try std.testing.expectEqual(pane_id, model.pointerSelection().?.pane_id);
    try std.testing.expect(model.pointerSelection().?.dragging);
    model.finishPointerGesture();
    try std.testing.expect(model.pointerSelection() == null);
}

test "copy mode frame reconciliation and pane release are exact" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 15, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 2, .y = 4 };
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    try std.testing.expect(!model.reconcileCopyModeFrame(.{
        .pane_id = @enumFromInt(2),
        .previous_offset = 10,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));
    try std.testing.expect(model.reconcileCopyModeFrame(.{
        .pane_id = pane_id,
        .previous_offset = 10,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));

    try std.testing.expectEqual(version.copy + 1, model.version().copy);
    try std.testing.expectEqual(@as(u32, 9), model.copyModeProjection().?.view.cursor.y);
    try std.testing.expect(!model.reconcileCopyModeFrame(.{
        .pane_id = pane_id,
        .previous_offset = 5,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));
    try std.testing.expect(!model.releaseCopyMode(@enumFromInt(2)));
    try std.testing.expect(model.releaseCopyMode(pane_id));
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expectEqual(version.copy + 2, model.version().copy);
}

pub const types = @import("types.zig");

pub const goto_picker = @import("goto_picker.zig");

pub const history_palette = @import("history_palette.zig");

pub const suggestion = @import("suggestion.zig");

pub const host = @import("host.zig");

pub const clipboard_capture = @import("clipboard_capture.zig");

pub const plugin_execution = @import("plugin_execution.zig");
