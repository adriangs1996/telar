//! Application command for changing one client's pane viewport.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment/root.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const SetPaneViewport = struct {
    pane_id: schema.PaneId,
    offset: u32,
};

pub const SetPaneViewportResult = enum {
    changed,
    unchanged,
    pane_not_attached,
};

pub const SetPaneViewportHandler = struct {
    attachments: *AttachmentStore,

    /// Changes only the requesting client's scrollback pin. Requests that
    /// resolve to the current offset are idempotent and do not schedule a new
    /// snapshot.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id, .offset = 0 });
    /// ```
    pub fn execute(handler: *SetPaneViewportHandler, command: SetPaneViewport) !SetPaneViewportResult {
        const update = try handler.attachments.setPaneViewport(.{
            .pane_id = command.pane_id,
            .offset = command.offset,
        }) orelse return .pane_not_attached;

        return switch (update) {
            .changed => .changed,
            .unchanged => .unchanged,
        };
    }
};

test "SetPaneViewportHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: SetPaneViewportHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(7),
        .offset = 0,
    });

    try std.testing.expectEqual(SetPaneViewportResult.pane_not_attached, result);
}
