const core = @import("telar-core");
const client = @import("telar-client");
const ModalInput = @This();

application: core.Rect,
snapshot: *const client.AttachmentSnapshot,
plan: *client.Plan,
graphical_frame: bool,
