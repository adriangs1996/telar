const Wake = @This();
const history = @import("../../history/root.zig");
const source_namespace = @import("pane_search.zig");
client: history.model.ClientKey,
request_id: source_namespace.schema.RequestId,
result: anyerror!void = {},
