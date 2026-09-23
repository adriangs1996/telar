const core = @import("telar-core");

pub const PaneGraphicsCommand = union(enum) {
    snapshot: core.Snapshot,
    image: core.SchemaImage,
    shared_image: core.SharedImage,
    image_chunk: core.ImageChunk,
    placement: core.SchemaPlacement,
    delete_image: core.DeleteImage,
    delete_placement: core.DeletePlacement,

    /// Returns the pane identity carried by every graphics command.
    ///
    /// ```zig
    /// const pane_id = command.paneId();
    /// ```
    pub fn paneId(self: PaneGraphicsCommand) core.PaneId {
        return switch (self) {
            inline else => |value| value.pane_id,
        };
    }
};
