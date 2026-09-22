const core = @import("telar-core");
const PaneMetadataKind = @import("PaneMetadataKind.zig").PaneMetadataKind;

pub const PaneMetadataCommand = union(PaneMetadataKind) {
    cwd: struct {
        pane_id: core.PaneId,
        /// Borrowed only for the synchronous transition.
        path: []const u8,
    },
    foreground: struct {
        pane_id: core.PaneId,
        /// Borrowed only for the synchronous transition.
        name: []const u8,
    },
    title: struct {
        pane_id: core.PaneId,
        /// Borrowed only for the synchronous transition; empty clears it.
        title: []const u8,
    },
};
