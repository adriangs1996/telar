//! Where a finished bar command's output goes.
const PanelRun = @import("PanelRun.zig");
const model = @import("../../bars/model.zig");

pub const CommandTarget = union(enum) {
    bar: model.Position,
    panel: PanelRun,
};
