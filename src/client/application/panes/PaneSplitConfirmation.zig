const PaneSplitConfirmation = @This();
const client_model = @import("../../root.zig").model;
const OpenedPane = @import("OpenedPane.zig");
requested: client_model.PaneSplit,
opened: OpenedPane,
