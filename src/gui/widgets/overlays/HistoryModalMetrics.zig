//! Native geometry needed by both the history painter and its scroll controller.
const Canvas = @import("../Canvas.zig");
const Metrics = @This();

viewport: @import("../../render/Rect.zig"),
chrome: @import("../ChromeMetrics.zig"),
terminal: @import("../../TerminalMetrics.zig"),

/// Example: `const metrics = HistoryModalMetrics.fromCanvas(canvas);`
pub fn fromCanvas(canvas: *const Canvas) Metrics {
    return .{ .viewport = .{ .x = 0, .y = 0, .width = @floatFromInt(canvas.viewport[0]), .height = @floatFromInt(canvas.viewport[1]) }, .chrome = canvas.chrome, .terminal = canvas.metrics };
}
