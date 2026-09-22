const model_data = @import("model");
/// Names the deletion being probed for a preview that has no slot yet.
const DeletionProbe = @This();

deletion: model_data.AttachmentMarkerDeletion,
policy: model_data.AttachmentMarkerPolicy = .ordered,
