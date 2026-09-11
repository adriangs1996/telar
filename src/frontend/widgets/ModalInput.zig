const ModalInput = @This();
const ui = @import("../ui/root.zig");
const attachments = @import("../attachments/root.zig");
application: ui.Rect,
snapshot: *const attachments.Snapshot,
plan: *attachments.Plan,
graphical_frame: bool,
