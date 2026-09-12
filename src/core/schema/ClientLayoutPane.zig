const id_module = @import("id.zig");
const types = @import("types.zig");
/// One layout leaf on the wire: the pane it shows and the surface showing it.
const ClientLayoutPane = @This();

id: id_module.PaneId,
surface: types.PaneSurface = .terminal,
