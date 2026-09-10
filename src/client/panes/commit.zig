//! Bounded presentation completion values. They never retain pane pointers.

const std = @import("std");
const schema = @import("telar-core").schema;
const Pane = @import("pane.zig").Pane;

pub const PresentationCommit = struct {
    location: ?schema.TabLocation = null,
    panes: [schema.max_panes_per_tab]PaneCommit = undefined,
    len: u8 = 0,

    pub const PaneCommit = struct {
        pane_id: schema.PaneId,
        frame_id: u64,
        attached: bool,
    };

    /// Borrows the exact completed pane identities. Example: for (commit.slice()) |pane| acknowledge(pane);
    pub fn slice(commit: *const PresentationCommit) []const PaneCommit {
        return commit.panes[0..commit.len];
    }

    /// Captures the pending frame without retaining model pointers.
    /// Example: commit.append(pane);
    pub fn append(commit: *PresentationCommit, pane: *const Pane) void {
        std.debug.assert(commit.len < commit.panes.len);
        commit.panes[commit.len] = .{
            .pane_id = pane.id,
            .frame_id = pane.pending_frame_id,
            .attached = pane.attached,
        };
        commit.len += 1;
    }
};
