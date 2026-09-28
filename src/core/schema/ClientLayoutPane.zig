const id_module = @import("id.zig");
/// One layout leaf on the wire: the pane it shows.
const ClientLayoutPane = @This();

id: id_module.PaneId,
