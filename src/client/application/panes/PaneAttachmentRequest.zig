const PaneAttachmentRequest = @This();
const source_namespace = @import("pane_attachment_requests.zig");
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
size: source_namespace.schema.TerminalSize,
