const PaneCommitType = @import("PaneCommit.zig");
const TabLocationType = @import("telar-core").TabLocation;
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const Pane = @import("Pane.zig");
const std = @import("std");
const PresentationCommit = @This();

location: ?TabLocationType = null,
panes: [max_panes_per_tab_module]PaneCommitType = undefined,
len: u8 = 0,

pub const PaneCommit = @import("PaneCommit.zig");

/// Borrows the exact completed pane identities. Example: for (commit.slice()) |pane| acknowledge(pane);
pub fn slice(commit: *const PresentationCommit) []const PaneCommitType {
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
        .attachment_generation = pane.attachment_generation,
    };
    commit.len += 1;
}
