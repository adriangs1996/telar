//! What one pointer sample in a chrome band asks for: a shared view
//! interaction, or a new sidebar width in device pixels while its edge is
//! being dragged. The width never enters the shared model.
interaction: @import("telar-client").ViewInteractionCommand = .{},
sidebar_width: ?u32 = null,
