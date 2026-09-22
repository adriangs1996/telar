const ScrollEffect = @import("../application/input/ScrollEffect.zig");
const ReportEffect = @import("../application/input/ReportEffect.zig");

pub const PaneMouseEffect = union(enum) {
    viewport: ScrollEffect,
    alternate_scroll: ScrollEffect,
    report: ReportEffect,
    selection: ReportEffect,
};
