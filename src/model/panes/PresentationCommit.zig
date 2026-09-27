const core = @import("telar-core");
const Pane = @import("Pane.zig");
const std = @import("std");
const PresentationCommit = @This();

location: ?core.TabLocation = null,
panes: [core.max_panes_per_tab]PaneCommit = undefined,
len: u8 = 0,

pub const PaneCommit = @import("PaneCommit.zig");

/// Borrows the exact completed pane identities. Example: for (commit.slice()) |pane| acknowledge(pane);
pub fn slice(self: *const PresentationCommit) []const PaneCommit {
    return self.panes[0..self.len];
}

/// Copies `source` without the unused tail of `panes`, kilobytes that a
/// whole-struct copy would move for one pane.
/// Example: `flight.delivery.commit.copyFrom(&submission.commit);`
pub fn copyFrom(self: *PresentationCommit, source: *const PresentationCommit) void {
    comptime std.debug.assert(std.meta.fields(PresentationCommit).len == 3);

    self.location = source.location;
    self.len = source.len;
    @memcpy(self.panes[0..source.len], source.slice());
}

/// Captures the pending frame without retaining model pointers.
/// Example: commit.append(pane);
pub fn append(self: *PresentationCommit, pane: *const Pane) void {
    std.debug.assert(self.len < self.panes.len);
    self.panes[self.len] = .{
        .pane_id = pane.id,
        .frame_id = pane.pending_frame_id,
        .attached = pane.attached,
        .attachment_generation = pane.attachment_generation,
    };
    self.len += 1;
}
