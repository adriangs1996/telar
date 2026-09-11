const RemovalCommand = @This();
const source_namespace = @import("attachment_prompt.zig");
const attachments = @import("../../attachments/root.zig");
pane_id: source_namespace.schema.PaneId,
marker: attachments.MarkerRemoval,
