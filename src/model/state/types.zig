//! Value contracts used by the ClientModel aggregate.

const core = @import("telar-core");
const graphics = @import("../environment/environment.zig");

pub const Change = @import("../types/Change.zig").Change;

pub const TabSelectionTarget = @import("../types/TabSelectionTarget.zig").TabSelectionTarget;

pub const PaneAttachmentConfirmation = @import("../types/StateTypesPaneAttachmentConfirmation.zig").StateTypesPaneAttachmentConfirmation;

pub const PaneFocusTarget = @import("../types/PaneFocusTarget.zig").PaneFocusTarget;

pub const max_window_title_template_bytes = 128;

pub const PluginExecutionId = @import("../types/PluginExecutionId.zig").PluginExecutionId;

pub const ClipboardCaptureId = @import("../types/ClipboardCaptureId.zig").ClipboardCaptureId;

pub const HostAppearance = @import("../types/HostAppearance.zig").HostAppearance;

pub const HostCapabilitySupport = @import("../types/HostCapabilitySupport.zig").HostCapabilitySupport;

pub const HostCapabilityObservation = @import("../types/HostCapabilityObservation.zig").HostCapabilityObservation;

pub fn observedSupport(support: HostCapabilitySupport) graphics.Support {
    return switch (support) {
        .unsupported => .unsupported,
        .supported => .supported,
    };
}

pub const AgentNavigationPlan = @import("../types/AgentNavigationPlan.zig").AgentNavigationPlan;

pub const PaneInputTarget = @import("../types/PaneInputTarget.zig").PaneInputTarget;

pub const PaneFrameOutcome = @import("../types/PaneFrameOutcome.zig").PaneFrameOutcome;

pub const PaneMetadataKind = @import("../types/PaneMetadataKind.zig").PaneMetadataKind;

pub const PaneMetadataCommand = @import("../types/PaneMetadataCommand.zig").PaneMetadataCommand;

pub const PaneViewportTarget = @import("../types/PaneViewportTarget.zig").PaneViewportTarget;

pub const CopyModeCommand = @import("../types/CopyModeCommand.zig").CopyModeCommand;

pub const PaneSplitDisposition = @import("../types/PaneSplitDisposition.zig").PaneSplitDisposition;

pub const PaneSplitRecovery = @import("../types/PaneSplitRecovery.zig").PaneSplitRecovery;

pub const PaneExit = @import("../types/PaneExit.zig").PaneExit;

pub const TabRemovalAbsence = @import("../types/TabRemovalAbsence.zig").TabRemovalAbsence;

pub const TabRemovalCommit = @import("../types/TabRemovalCommit.zig").TabRemovalCommit;
