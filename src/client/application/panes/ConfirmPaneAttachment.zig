const ConfirmPaneAttachment = @This();
const source_namespace = @import("attach_pane.zig");
requested: source_namespace.PaneAttachment,
confirmed: source_namespace.PaneAttachment,
created: bool,
