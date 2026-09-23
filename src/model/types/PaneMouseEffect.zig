const ScrollEffect = @import("../input/ScrollEffect.zig");
const ReportEffect = @import("../input/ReportEffect.zig");

pub const PaneMouseEffect = union(enum) {
    viewport: ScrollEffect,
    alternate_scroll: ScrollEffect,
    report: ReportEffect,
    selection: ReportEffect,
};
