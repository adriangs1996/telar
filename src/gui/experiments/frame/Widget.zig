//! The challenge statement, one small input/output example, and optional timings.
const std = @import("std");
const event = @import("../../input/event.zig");
const problem = @import("problem.zig");
const benchmark = @import("benchmark.zig");
const Canvas = @import("../../widgets/Canvas.zig");
const FormButton = @import("../../widgets/FormButton.zig");
const Route = @import("../../widgets/interaction/Route.zig");
const Demo = @import("Demo.zig");
const Measurement = @import("Measurement.zig");
const Self = @This();

const labels = [_][]const u8{ "N Repeat", "1 Edit A", "2 Grow A", "3 Shrink A", "4 Swap", "R Reset", "B Measure" };
const measure_action = labels.len;

demo: Demo = .{},
measure_requested: bool = false,
results: ?[benchmark.names.len]Measurement = null,
io: std.Io,

/// Example: `try widget.draw(&canvas);`
pub fn draw(self: *Self, canvas: *Canvas) !void {
    if (self.demo.steps == 0) {
        try self.demo.step(.reset);
    }

    if (self.measure_requested) {
        self.results = try benchmark.run(canvas.quads.allocator, self.io);
        self.measure_requested = false;
    }

    try line(canvas, 12, "Challenge: maintain a contiguous frame");
    try line(canvas, 44, "solve(blocks: []const Block, frame: *Frame) !Cost");
    try line(canvas, 76, "Input: ordered blocks with id, revision and Quad[]. Output: their exact concatenation.");
    try line(canvas, 104, "Output survives calls. No allocation. No input aliases. Never modify a frame in flight.");
    const width = @as(f32, @floatFromInt(canvas.viewport[0])) - canvas.chrome.px(40);
    const button_width = @max(0, (width - canvas.chrome.px(6 * (labels.len - 1))) / labels.len);
    for (labels, 0..) |label, index| {
        try (FormButton{
            .bounds = .{ .x = canvas.chrome.px(20) + @as(f32, @floatFromInt(index)) * (button_width + canvas.chrome.px(6)), .y = canvas.chrome.px(148), .width = button_width, .height = canvas.chrome.px(32) },
            .text = label,
            .action = .{ .custom = index + 1 },
            .generation = 1,
            .namespace = 1,
        }).draw(canvas);
    }

    var text: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try writer.print("A: revision {d}, values [", .{self.demo.revision});
    for (self.demo.a[0..self.demo.a_len], 0..) |item, index| {
        try writer.print("{s}{d:.0}", .{ if (index == 0) "" else ", ", item.x });
    }

    try writer.writeAll("]");
    try line(canvas, 204, writer.buffered());
    try line(canvas, 236, if (self.demo.reversed) "B: revision 1, values [8, 9]. Current order: B then A." else "B: revision 1, values [8, 9]. Current order: A then B.");
    writer = .fixed(&text);
    try writer.writeAll("Output = [");
    for (self.demo.output[0..self.demo.frame.len], 0..) |item, index| {
        try writer.print("{s}{d:.0}", .{ if (index == 0) "" else ", ", item.x });
    }

    try writer.writeAll("]   MATCHES reference byte for byte");
    try line(canvas, 272, writer.buffered());
    try line(canvas, 316, try std.fmt.bufPrint(&text, "REBUILD: {d} block visits; {d} quads copied; {d} bytes written", .{ self.demo.reference_cost.block_visits, self.demo.reference_cost.quads_copied, self.demo.reference_cost.quads_copied * problem.bytes_per_quad }));
    try line(canvas, 348, try std.fmt.bufPrint(&text, "SOLVE:     {d} block visits; {d} quads copied; {d} bytes written", .{ self.demo.cost.block_visits, self.demo.cost.quads_copied, self.demo.cost.quads_copied * problem.bytes_per_quad }));
    try line(canvas, 388, "One value represents one real 80-byte Quad. Counts are logical work, not CPU instructions.");
    try line(canvas, 420, "Starter: skip unchanged blocks; copy changed blocks; rebuild everything if lengths/order change.");
    try line(canvas, 452, "Edit src/gui/experiments/frame/problem.zig -> solve. Next: keep unaffected blocks on resize.");
    if (self.results) |results| {
        try line(canvas, 504, "Composition only, two 1600-quad blocks. Mean ns/call: rebuild | solve. No renderer/GPU timing.");
        for (results, 0..) |result, index| {
            const samples: f64 = @floatFromInt(result.samples);
            try line(canvas, 536 + @as(f32, @floatFromInt(index)) * 28, try std.fmt.bufPrint(&text, "{s}: {d:.1} | {d:.1} ns; solve copies {d:.1} quads/call", .{
                result.name,
                @as(f64, @floatFromInt(result.reference_ns)) / samples,
                @as(f64, @floatFromInt(result.solution_ns)) / samples,
                @as(f64, @floatFromInt(result.solution_quads)) / samples,
            }));
        }
    } else {
        try line(canvas, 504, "B measures the two functions on larger arrays. Keyboard/clicks change only the example above.");
        try line(canvas, 536, "Worst case: every block changes. Separate contiguous output still requires writing all Q quads.");
        try line(canvas, 568, "Zero-copy would change the contract: generate directly in output, or let the consumer accept blocks.");
    }
}

/// Example: `const changed = try widget.input(event, route);`
pub fn input(self: *Self, value: event.Event, route: Route) !bool {
    const action: usize = switch (value) {
        .text => |text| if (text.bytes.len == 1 and text.target_id == 0) switch (text.bytes[0]) {
            'n', 'N', ' ' => 1,
            '1'...'4' => text.bytes[0] - '1' + 2,
            'r', 'R' => 6,
            'b', 'B' => measure_action,
            else => return false,
        } else return false,
        .pointer => |pointer| blk: {
            const target = route.target orelse return false;
            if (pointer.kind != .release or pointer.button != .left or target.action != .custom or !target.contains(.{ pointer.x, pointer.y })) {
                return false;
            }

            break :blk @intCast(target.action.custom);
        },
        else => return false,
    };
    if (action == measure_action) {
        self.measure_requested = true;
    } else if (action >= 1 and action <= @intFromEnum(Demo.Action.reset) + 1) {
        try self.demo.step(@enumFromInt(action - 1));
    } else {
        return false;
    }

    return true;
}

fn line(canvas: *Canvas, y: f32, text: []const u8) !void {
    _ = try canvas.textAt(.{ .x = canvas.chrome.px(20), .y = canvas.chrome.px(y), .width = @max(0, @as(f32, @floatFromInt(canvas.viewport[0])) - canvas.chrome.px(40)), .height = canvas.chrome.px(26) }, .{
        .text = text,
        .color = canvas.theme.palette.text,
        .face = .sans,
        .size = if (y == 12) .title else .body,
        .bold = y == 12,
    });
}
