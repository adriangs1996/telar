//! Value contracts used by the ClientModel aggregate.

const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const layout_mod = @import("../workspace/layout_support.zig");
const PixelSize = @import("PixelSize.zig");
const graphics = @import("../environment/environment.zig");
const LocalAgentNavigation = @import("LocalAgentNavigation.zig");
const AgentHandoff = @import("AgentHandoff.zig");
const PanePasteSession = @import("PanePasteSession.zig");
const PaneFrameRecovery = @import("PaneFrameRecovery.zig");
const PaneFrameCommit = @import("PaneFrameCommit.zig");
const KeyType = @import("../input/Key.zig");
const PointerMotionType = @import("../input/PointerMotion.zig");
const CopyModeMatches = @import("CopyModeMatches.zig");
const PaneResize = @import("telar-core").PaneResize;
const PaneRetirement = @import("PaneRetirement.zig");
const StalePaneExit = @import("StalePaneExit.zig");
const TabRemoval = @import("TabRemoval.zig");
const StaleTabRemoval = @import("StaleTabRemoval.zig");

pub const Change = enum {
    unchanged,
    changed,
};

pub const TabSelectionTarget = union(enum) {
    tab_id: TabIdType,
    offset: isize,
    position: usize,
};

pub const PaneAttachmentConfirmation = enum {
    confirmed,
    stale,
};

pub const PaneFocusTarget = union(enum) {
    pane_id: PaneIdType,
    direction: layout_mod.Direction,
};

pub const max_window_title_template_bytes = 128;

pub const PluginExecutionId = enum(u64) {
    none = 0,
    _,
};

pub const ClipboardCaptureId = enum(u64) {
    none = 0,
    _,
};

pub const HostAppearance = enum { unknown, light, dark };

pub const HostCapabilitySupport = enum { unsupported, supported };

pub const HostCapabilityObservation = union(enum) {
    images: HostCapabilitySupport,
    window_pixels: PixelSize,
    cell_pixels: PixelSize,
    pointer_pixels: HostCapabilitySupport,
    foreground: struct { r: u8, g: u8, b: u8 },
    background: struct { r: u8, g: u8, b: u8 },
};

pub fn observedSupport(support: HostCapabilitySupport) graphics.Support {
    return switch (support) {
        .unsupported => .unsupported,
        .supported => .supported,
    };
}

pub const AgentNavigationPlan = union(enum) {
    local: LocalAgentNavigation,
    handoff: AgentHandoff,
};

pub const PaneInputTarget = union(enum) {
    focused,
    pane: PaneIdType,
    key_lease: PaneIdType,
    paste_session: PanePasteSession,
};

pub const PaneFrameOutcome = union(enum) {
    detached,
    resync: PaneFrameRecovery,
    applied: PaneFrameCommit,
};

pub const PaneMetadataKind = enum {
    cwd,
    foreground,
    title,
};

pub const PaneMetadataCommand = union(PaneMetadataKind) {
    cwd: struct {
        pane_id: PaneIdType,
        /// Borrowed only for the synchronous transition.
        path: []const u8,
    },
    foreground: struct {
        pane_id: PaneIdType,
        /// Borrowed only for the synchronous transition.
        name: []const u8,
    },
    title: struct {
        pane_id: PaneIdType,
        /// Borrowed only for the synchronous transition; empty clears it.
        title: []const u8,
    },
};

pub const PaneViewportTarget = union(enum) {
    absolute: u32,
    relative: i32,
    bottom,
};

pub const CopyModeCommand = union(enum) {
    key: KeyType,
    pointer: PointerMotionType,
    cancel_pointer,
    vertical: i32,
    matches: CopyModeMatches,
    leave,
};

pub const PaneSplitDisposition = enum {
    active,
    inactive,
    stale,
};

pub const PaneSplitRecovery = union(enum) {
    resize: PaneResize,
    not_required,
    stale,
};

pub const PaneExit = union(enum) {
    retired: PaneRetirement,
    stale: StalePaneExit,
};

pub const TabRemovalAbsence = enum {
    workspace,
    tab,
};

pub const TabRemovalCommit = union(enum) {
    removed: TabRemoval,
    stale: StaleTabRemoval,
};
