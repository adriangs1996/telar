const PaneSplitType = @import("../../model/PaneSplit.zig");
const OpenedPane = @import("OpenedPane.zig");
const PaneSplitConfirmation = @This();

requested: PaneSplitType,
opened: OpenedPane,
