const Command = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_input.zig");
target: client_model.PaneInputTarget,
source: source_namespace.Source,
payload: source_namespace.Payload,
