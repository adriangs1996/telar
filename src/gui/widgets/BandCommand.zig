//! What one pointer sample in a chrome band asks for: a shared view
//! interaction, or a new sidebar width in device pixels while its edge is
//! being dragged. The width never enters the shared model.
const client = @import("telar-client");
interaction: client.ViewInteractionCommand = .{},
sidebar_width: ?u32 = null,
