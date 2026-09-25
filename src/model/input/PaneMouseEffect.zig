const ScrollEffect = @import("ScrollEffect.zig");
const ReportEffect = @import("ReportEffect.zig");

pub const PaneMouseEffect = union(enum) {
    viewport: ScrollEffect,
    alternate_scroll: ScrollEffect,
    report: ReportEffect,
    selection: ReportEffect,
};
