const RectType = @import("telar-core").Rect;
const SnapshotType = @import("telar-client").AttachmentSnapshot;
const PlanType = @import("telar-client").Plan;
const ModalInput = @This();

application: RectType,
snapshot: *const SnapshotType,
plan: *PlanType,
graphical_frame: bool,
