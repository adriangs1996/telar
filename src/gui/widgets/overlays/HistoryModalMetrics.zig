//! Native geometry needed by both the history painter and its scroll controller.
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const ChromeMetrics = @import("../ChromeMetrics.zig");
const TerminalMetrics = @import("../../TerminalMetrics.zig");
const Metrics = @This();

viewport: Rect,
chrome: ChromeMetrics,
terminal: TerminalMetrics,

/// Example: `const metrics = HistoryModalMetrics.fromCanvas(canvas);`
pub fn fromCanvas(canvas: *const Canvas) Metrics {
    return .{ .viewport = .{ .x = 0, .y = 0, .width = @floatFromInt(canvas.viewport[0]), .height = @floatFromInt(canvas.viewport[1]) }, .chrome = canvas.chrome, .terminal = canvas.metrics };
}
