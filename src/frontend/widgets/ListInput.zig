const ListInput = @This();
const ui = @import("../ui/root.zig");
const source_namespace = @import("top_bar.zig");
area: ui.Rect,
active_id: ?source_namespace.schema.WorkspaceId,
