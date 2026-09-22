const core = @import("telar-core");
const model_data = @import("model");
const MarkerBoundary = @This();

ordinal: u16,
cursor: core.Cursor,
deletion: model_data.AttachmentMarkerDeletion,
